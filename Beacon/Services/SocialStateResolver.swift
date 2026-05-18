import Foundation
import Combine

@MainActor
final class SocialStateResolver: ObservableObject {
    static let shared = SocialStateResolver()

    enum SocialMode: String {
        case preEventPreparation
        case earlyArrival
        case liveNavigation
    }

    struct State: Equatable {
        enum PresenceConfidence: String, Equatable {
            case stableLive
            case transientLoss
            case recentlySeen
            case unstable
        }

        let mode: SocialMode
        let activeAttendeeCount: Int
        let hasBLEOnlyNearby: Bool
        let hasRenderableRecommendations: Bool
        let canLaunchFind: Bool
        let canShowWhosHere: Bool
        let canPreviewLikelyArrivals: Bool
        let hasRecentlyNearby: Bool
        let presenceConfidence: PresenceConfidence
    }

    @Published private(set) var state: State = .init(
        mode: .preEventPreparation,
        activeAttendeeCount: 0,
        hasBLEOnlyNearby: false,
        hasRenderableRecommendations: false,
        canLaunchFind: false,
        canShowWhosHere: false,
        canPreviewLikelyArrivals: true,
        hasRecentlyNearby: false,
        presenceConfidence: .unstable
    )

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var modeEnteredAt: Date = .distantPast
    private var lastLiveAttendeeSeenAt: Date?
    private var lastAnyPresenceSeenAt: Date?
    private var retainedRecommendationUntil: Date?
    private var lastRecommendationSnapshot = false

    private let liveRetentionWindow: TimeInterval = 20
    private let liveModeExitHysteresis: TimeInterval = 12
    private let earlyArrivalExitHysteresis: TimeInterval = 10
    private let recommendationRetentionWindow: TimeInterval = 18
    private let recentlyNearbyWindow: TimeInterval = 45

    private init() {
        subscribe()
        recalculate(reason: "init")
    }

    deinit { timer?.invalidate() }

    func canLaunchFind(for recommendation: PreEventBriefBuilder.PriorityPerson?) -> Bool {
        guard let recommendation else {
            logFindEligibility(person: nil, allowed: false, reason: "person missing", matchedAttendee: nil, fresh: false, blePrefix: nil, bleVisible: false)
            return false
        }

        let attendees = EventAttendeesService.shared.attendees
        let matchedAttendee = attendees.first(where: { $0.id == recommendation.id })
        let fresh = matchedAttendee?.isActiveNow ?? false
        let mode = state.mode
        let blePrefix = localCommunityPrefix(from: recommendation.id)
        let bleVisible = BLEScannerService.shared.getFilteredDevices().contains { device in
            guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { return false }
            return prefix == blePrefix
        }

        let allowed = state.canLaunchFind && fresh && matchedAttendee != nil

        let reason: String
        if !state.canLaunchFind {
            reason = "mode \(mode.rawValue) does not allow find"
        } else if matchedAttendee == nil {
            reason = "profileId mismatch between brief recommendation and live attendee"
        } else if !fresh {
            reason = "matched attendee is not fresh/live"
        } else {
            reason = "matched live attendee is resolvable"
        }

        logFindEligibility(
            person: recommendation,
            allowed: allowed,
            reason: reason,
            matchedAttendee: matchedAttendee,
            fresh: fresh,
            blePrefix: blePrefix,
            bleVisible: bleVisible
        )
        return allowed
    }

    private func subscribe() {
        EventJoinService.shared.objectWillChange
            .merge(with: EventAttendeesService.shared.objectWillChange)
            .merge(with: BLEScannerService.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate(reason: "publisher") }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recalculate(reason: "timer")
            }
        }
    }


    private func localCommunityPrefix(from id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private func localCommunityPrefix(from id: String) -> String {
        String(id.prefix(8)).lowercased()
    }

    private func recalculate(reason: String) {
        let joined = EventJoinService.shared.isEventJoined
        let checkedIn = EventJoinService.shared.isCheckedIn
        let activeCount = EventAttendeesService.shared.liveOtherCount

        let bleDevices = BLEScannerService.shared.getFilteredDevices()
        let now = Date()
        let freshBLE = bleDevices.filter { now.timeIntervalSince($0.lastSeen) <= 15 }
        let resolvedLiveIds = Set(EventAttendeesService.shared.attendees.map(\.id))
        let unresolvedBle = freshBLE.filter { dev in
            guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: dev.name) else { return true }
            return !resolvedLiveIds.contains { $0.uuidString.lowercased().hasPrefix(prefix) }
        }

        let mode: SocialMode
        if !checkedIn {
            mode = .preEventPreparation
        } else if activeCount == 0 {
            mode = .earlyArrival
        } else {
            mode = .liveNavigation
        }

        if activeCount > 0 {
            lastLiveAttendeeSeenAt = now
            lastAnyPresenceSeenAt = now
        } else if !freshBLE.isEmpty {
            lastAnyPresenceSeenAt = now
        }

        let confidence = resolvePresenceConfidence(activeCount: activeCount, hasFreshBLE: !freshBLE.isEmpty, joined: joined, checkedIn: checkedIn, now: now)
        let stabilizedMode = stabilizedModeFor(
            candidate: mode,
            confidence: confidence,
            checkedIn: checkedIn,
            now: now
        )

        let recommendationsRenderable = stabilizedRecommendationsRenderable(joined: joined, now: now)
        lastRecommendationSnapshot = recommendationsRenderable
        let next = State(
            mode: stabilizedMode,
            activeAttendeeCount: activeCount,
            hasBLEOnlyNearby: !unresolvedBle.isEmpty,
            hasRenderableRecommendations: recommendationsRenderable,
            canLaunchFind: stabilizedMode == .liveNavigation,
            canShowWhosHere: stabilizedMode == .liveNavigation && (activeCount > 0 || confidence == .transientLoss),
            canPreviewLikelyArrivals: stabilizedMode != .liveNavigation,
            hasRecentlyNearby: hasRecentlyNearby(now: now),
            presenceConfidence: confidence
        )

        if next != state {
            if next.mode != state.mode {
                modeEnteredAt = now
            }
            state = next
            #if DEBUG
            print("[SocialResolver] mode=\(next.mode.rawValue) joined=\(joined) checkedIn=\(checkedIn) active=\(activeCount) bleOnly=\(next.hasBLEOnlyNearby) reason=\(reason)")
            print("[PresenceResolver] activeCount=\(activeCount) checkedIn=\(checkedIn) canWhoHere=\(next.canShowWhosHere)")
            print("[RecommendationResolver] renderable=\(next.hasRenderableRecommendations) previewLikely=\(next.canPreviewLikelyArrivals)")
            print("[BLEClassification] fresh=\(freshBLE.count) unresolved=\(unresolvedBle.count) resolvedLive=\(resolvedLiveIds.count)")
            print("[PresenceStability] confidence=\(next.presenceConfidence.rawValue) recentlyNearby=\(next.hasRecentlyNearby)")
            #endif
        }
    }

    private func resolvePresenceConfidence(activeCount: Int, hasFreshBLE: Bool, joined: Bool, checkedIn: Bool, now: Date) -> State.PresenceConfidence {
        if activeCount > 0 { return .stableLive }
        if let lastLiveAttendeeSeenAt, now.timeIntervalSince(lastLiveAttendeeSeenAt) <= liveRetentionWindow {
            #if DEBUG
            print("[TransientLoss] active attendees dropped but within live retention window")
            #endif
            return .transientLoss
        }
        if checkedIn && joined && hasRecentlyNearby(now: now) {
            return .recentlySeen
        }
        if hasFreshBLE {
            #if DEBUG
            print("[TransientLoss] BLE visibility present while backend currently empty")
            #endif
            return .transientLoss
        }
        return .unstable
    }

    private func stabilizedModeFor(candidate: SocialMode, confidence: State.PresenceConfidence, checkedIn: Bool, now: Date) -> SocialMode {
        if !checkedIn { return .preEventPreparation }
        if candidate == .liveNavigation { return .liveNavigation }

        if state.mode == .liveNavigation && candidate != .liveNavigation {
            if confidence == .transientLoss, let lastLiveAttendeeSeenAt {
                let heldFor = now.timeIntervalSince(lastLiveAttendeeSeenAt)
                if heldFor <= liveModeExitHysteresis {
                    #if DEBUG
                    print("[ModeHysteresis] preserving liveNavigation for \(Int(heldFor))s after transient loss")
                    print("[LiveRetention] retaining live mode during temporary attendee gap")
                    #endif
                    return .liveNavigation
                }
            }
        }

        if state.mode == .earlyArrival && candidate == .preEventPreparation {
            let elapsed = now.timeIntervalSince(modeEnteredAt)
            if elapsed < earlyArrivalExitHysteresis {
                #if DEBUG
                print("[ModeHysteresis] preserving earlyArrival for \(Int(elapsed))s to avoid flip")
                #endif
                return .earlyArrival
            }
        }

        return candidate
    }

    private func stabilizedRecommendationsRenderable(joined: Bool, now: Date) -> Bool {
        if joined {
            retainedRecommendationUntil = now.addingTimeInterval(recommendationRetentionWindow)
            return true
        }
        if let retainedRecommendationUntil, now <= retainedRecommendationUntil, lastRecommendationSnapshot {
            #if DEBUG
            print("[RecommendationRetention] preserving recent recommendation during refresh gap")
            #endif
            return true
        }
        return false
    }

    private func hasRecentlyNearby(now: Date) -> Bool {
        guard let lastAnyPresenceSeenAt else { return false }
        let age = now.timeIntervalSince(lastAnyPresenceSeenAt)
        if age <= recentlyNearbyWindow {
            #if DEBUG
            if age > 1 {
                print("[PresenceStability] recently nearby signal retained (\(Int(age))s ago)")
            }
            #endif
            return true
        }
        return false
    }

    private func logFindEligibility(
        person: PreEventBriefBuilder.PriorityPerson?,
        allowed: Bool,
        reason: String,
        matchedAttendee: EventAttendee?,
        fresh: Bool,
        blePrefix: String?,
        bleVisible: Bool
    ) {
        #if DEBUG
        let activeIds = EventAttendeesService.shared.attendees.map { $0.id.uuidString.uppercased() }.joined(separator: ",")
        let targetName = person?.name ?? "none"
        let targetId = person?.id.uuidString.uppercased() ?? "none"
        let matchedId = matchedAttendee?.id.uuidString.uppercased() ?? "none"
        print("[FindEligibility] target=\(targetName) targetProfileId=\(targetId) mode=\(state.mode.rawValue) fresh=\(fresh) matchedLiveAttendee=\(matchedAttendee != nil) matchedAttendeeId=\(matchedId) activeIds=[\(activeIds)] blePrefix=\(blePrefix ?? "none") bleVisible=\(bleVisible) backendFresh=\(fresh) allowed=\(allowed) reason=\(reason)")
        #endif
    }
}
