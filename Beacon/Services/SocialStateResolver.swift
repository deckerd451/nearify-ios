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
        let mode: SocialMode
        let activeAttendeeCount: Int
        let hasBLEOnlyNearby: Bool
        let hasRenderableRecommendations: Bool
        let canLaunchFind: Bool
        let canShowWhosHere: Bool
        let canPreviewLikelyArrivals: Bool
    }

    @Published private(set) var state: State = .init(
        mode: .preEventPreparation,
        activeAttendeeCount: 0,
        hasBLEOnlyNearby: false,
        hasRenderableRecommendations: false,
        canLaunchFind: false,
        canShowWhosHere: false,
        canPreviewLikelyArrivals: true
    )

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

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
        let blePrefix = BLEAdvertiserService.communityPrefix(from: recommendation.id)
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
            Task { @MainActor in self?.recalculate(reason: "timer") }
        }
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
        if !checkedIn { mode = .preEventPreparation }
        else if activeCount == 0 { mode = .earlyArrival }
        else { mode = .liveNavigation }

        let recommendationsRenderable = joined
        let canLaunchFind = mode == .liveNavigation
        let next = State(
            mode: mode,
            activeAttendeeCount: activeCount,
            hasBLEOnlyNearby: !unresolvedBle.isEmpty,
            hasRenderableRecommendations: recommendationsRenderable,
            canLaunchFind: canLaunchFind,
            canShowWhosHere: mode == .liveNavigation && activeCount > 0,
            canPreviewLikelyArrivals: mode != .liveNavigation
        )

        if next != state {
            state = next
            #if DEBUG
            print("[SocialResolver] mode=\(next.mode.rawValue) joined=\(joined) checkedIn=\(checkedIn) active=\(activeCount) bleOnly=\(next.hasBLEOnlyNearby) reason=\(reason)")
            print("[PresenceResolver] activeCount=\(activeCount) checkedIn=\(checkedIn) canWhoHere=\(next.canShowWhosHere)")
            print("[RecommendationResolver] renderable=\(next.hasRenderableRecommendations) previewLikely=\(next.canPreviewLikelyArrivals)")
            print("[BLEClassification] fresh=\(freshBLE.count) unresolved=\(unresolvedBle.count) resolvedLive=\(resolvedLiveIds.count)")
            #endif
        }
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
