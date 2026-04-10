import Foundation
import Combine

/// Maslow-aligned, time-aware intelligence surface.
/// Answers: What matters right now? What should I do next? What should I not lose?
///
/// Sections rendered in strict order: CONTINUE → INSIGHTS → NEXT MOVES.
/// Items are suppressed when timing + signal thresholds are not met,
/// or when the user has already acted on them (via SurfaceMemory).
@MainActor
final class HomeSurfaceService: ObservableObject {

    static let shared = HomeSurfaceService()

    @Published private(set) var continueItems: [HomeSurfaceItem] = []
    @Published private(set) var insightItems: [HomeSurfaceItem] = []
    @Published private(set) var nextMoveItems: [HomeSurfaceItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    // Event context for the strip
    @Published private(set) var liveEventName: String?
    @Published private(set) var liveAttendeeCount: Int = 0

    private let memory = SurfaceMemory.shared
    private var isRefreshing = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Section Caps (tightened)
    private enum Cap {
        static let `continue` = 2   // was 3 — must require immediate action
        static let insights = 1     // was 2 — only meaningful patterns
        static let nextMoves = 2
    }

    // MARK: - Signal Thresholds
    private enum Threshold {
        static let continueMinPriority: Double = 0.05
        static let insightMinEncounterSeconds: Int = 120
        static let insightMinEncounterCount: Int = 2
        static let nextMoveMinPriority: Double = 0.02
    }

    private init() {}

    // MARK: - Public API

    var isEmpty: Bool {
        continueItems.isEmpty && insightItems.isEmpty && nextMoveItems.isEmpty
    }

    var isAtEvent: Bool {
        EventJoinService.shared.isEventJoined
    }

    func requestRefresh(reason: String) {
        guard !isRefreshing else { return }

        #if DEBUG
        print("[Surface] 🔄 Refresh: \(reason)")
        #endif

        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task {
            await buildSurface()
            isRefreshing = false
        }
    }

    /// Called by action handlers to immediately remove/suppress an item.
    func recordAction(item: HomeSurfaceItem) {
        memory.recordAction(
            profileId: item.profileId,
            eventId: item.eventId,
            section: item.section,
            actionType: item.actionType
        )

        // Immediate removal for permanent actions
        switch item.actionType {
        case .reply, .message, .followUp:
            continueItems.removeAll { $0.profileId == item.profileId && $0.section == .continue }
            nextMoveItems.removeAll { $0.profileId == item.profileId }
        case .jumpBack:
            nextMoveItems.removeAll { $0.actionType == .jumpBack }
        case .connect:
            insightItems.removeAll { $0.profileId == item.profileId }
        case .findAttendee, .viewProfile:
            break // cooldown only, no immediate removal
        }
    }

    // MARK: - Surface Builder

    private func buildSurface() async {
        isLoading = true
        defer { isLoading = false }

        guard let myId = AuthService.shared.currentUser?.id else { return }

        let feedItems = FeedService.shared.feedItems
        let activeEncounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let isAtEvent = EventJoinService.shared.isEventJoined
        let eventName = EventJoinService.shared.currentEventName
        let eventIdStr = EventJoinService.shared.currentEventID
        let eventId = eventIdStr.flatMap { UUID(uuidString: $0) }
        let attendees = EventAttendeesService.shared.attendees

        // Update event context strip
        liveEventName = isAtEvent ? eventName : nil
        liveAttendeeCount = isAtEvent ? attendees.count : 0

        let eventDensity = min(Double(attendees.count) / 50.0, 1.0)

        // Build avatar lookup from attendees + feed metadata
        var avatarMap: [UUID: String] = [:]
        for a in attendees { if let url = a.avatarUrl { avatarMap[a.id] = url } }
        for item in feedItems { if let id = item.actorProfileId, let url = item.metadata?.actorAvatarUrl { avatarMap[id] = url } }

        var continuePool: [HomeSurfaceItem] = []
        var insightPool: [HomeSurfaceItem] = []
        var nextMovePool: [HomeSurfaceItem] = []

        // ── CONTINUE: Unread messages ──
        let messageItems = feedItems.filter { $0.feedType == .message }
        for item in messageItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)

            // Memory check: skip if already replied
            guard !memory.isSuppressed(profileId: actorId, eventId: nil, section: .continue) else { continue }

            let signalStrength = signalForMessage(age: age)
            let temporal = TemporalResolver.resolve(lastSeenAge: age, signalStrength: signalStrength, eventDensity: eventDensity)
            guard temporal == .immediate || temporal == .live else { continue }

            let priority = TemporalResolver.temporalPriority(lastSeenAge: age, signalStrength: signalStrength)
            guard priority >= Threshold.continueMinPriority else { continue }

            let name = firstName(item.metadata?.actorName ?? "Someone")
            continuePool.append(HomeSurfaceItem(
                section: .continue, profileId: actorId, name: name,
                avatarUrl: avatarMap[actorId],
                headline: "Reply to \(name)",
                subtitle: item.metadata?.messagePreview,
                actionType: .reply, actionLabel: "Reply",
                temporalState: temporal, priority: priority + 0.5,
                conversationId: item.metadata?.conversationId.flatMap { UUID(uuidString: $0) }
            ))
        }

        // ── CONTINUE: Immediate/live encounters ──
        if isAtEvent {
            for (profileId, tracker) in activeEncounters {
                guard profileId != myId else { continue }
                guard !memory.isSuppressed(profileId: profileId, eventId: eventId, section: .continue) else { continue }

                let age = Date().timeIntervalSince(tracker.lastSeen)
                let overlapStrength = signalForEncounter(overlapSeconds: tracker.totalSeconds)
                let temporal = TemporalResolver.resolve(lastSeenAge: age, signalStrength: overlapStrength, eventDensity: eventDensity)
                guard temporal == .immediate || temporal == .live else { continue }

                let priority = TemporalResolver.temporalPriority(lastSeenAge: age, signalStrength: overlapStrength)
                guard priority >= Threshold.continueMinPriority else { continue }

                let attendee = attendees.first(where: { $0.id == profileId })
                let name = firstName(attendee?.name ?? "Someone")
                let isConnected = connectedIds.contains(profileId)
                let minutes = tracker.totalSeconds / 60

                let headline: String
                let subtitle: String?
                if temporal == .immediate {
                    headline = "\(name) is nearby — go say hi"
                    subtitle = contextLine(eventName: eventName, minutes: minutes)
                } else {
                    headline = "Find \(name)"
                    subtitle = contextLine(eventName: eventName, minutes: minutes, verb: "You crossed paths")
                }

                continuePool.append(HomeSurfaceItem(
                    section: .continue, profileId: profileId, name: name,
                    avatarUrl: avatarMap[profileId],
                    headline: headline, subtitle: subtitle,
                    actionType: .findAttendee,
                    actionLabel: isConnected ? "Go say hi" : "Find",
                    temporalState: temporal,
                    priority: temporal == .immediate ? priority + 0.3 : priority,
                    eventId: eventId, eventName: eventName, isFind: true
                ))
            }
        }

        // ── CONTINUE: Very recent strong encounters from DB ──
        let encounterItems = feedItems.filter { $0.feedType == .encounter }
        for item in encounterItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard activeEncounters[actorId] == nil else { continue }
            guard !memory.isSuppressed(profileId: actorId, eventId: item.eventId, section: .continue) else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)
            let overlap = item.metadata?.overlapSeconds ?? 0
            let strength = signalForEncounter(overlapSeconds: overlap)
            let temporal = TemporalResolver.resolve(lastSeenAge: age, signalStrength: strength, eventDensity: eventDensity)
            guard temporal == .immediate || temporal == .live else { continue }
            guard strength >= 0.3 else { continue }

            let priority = TemporalResolver.temporalPriority(lastSeenAge: age, signalStrength: strength)
            let name = firstName(item.metadata?.actorName ?? "Someone")
            let isConnected = connectedIds.contains(actorId)
            let minutes = overlap / 60

            continuePool.append(HomeSurfaceItem(
                section: .continue, profileId: actorId, name: name,
                avatarUrl: avatarMap[actorId],
                headline: isConnected ? "\(name) is nearby — go say hi" : "Find \(name)",
                subtitle: contextLine(eventName: item.metadata?.eventName, minutes: minutes, verb: "You crossed paths"),
                actionType: .findAttendee,
                actionLabel: isConnected ? "Go say hi" : "Find",
                temporalState: temporal, priority: priority,
                eventId: item.eventId, eventName: item.metadata?.eventName, isFind: true
            ))
        }

        // ── INSIGHTS: Non-obvious patterns from real interaction data ──
        if isAtEvent {
            let encounterMap = buildEncounterMap(myId: myId, eventId: eventId)
            let lastMessageTimes = await buildMessageTimeMap(myId: myId)
            let viewerProfile = AuthService.shared.currentUser

            let signals = InteractionInsightService.shared.buildSignals(
                attendees: attendees, encounters: encounterMap,
                connectedIds: connectedIds, lastMessageTimes: lastMessageTimes,
                viewerProfile: viewerProfile, myId: myId
            )
            let insights = InteractionInsightService.shared.generateInsights(from: signals)

            for insight in insights {
                guard insight.confidence >= 0.5 else { continue }
                guard insight.encounterMinutes >= 2 || insight.sharedInterests.count >= 2 else { continue }
                guard !memory.isSuppressed(profileId: insight.profileId, eventId: eventId, section: .insights) else { continue }

                // No duplication from Continue
                guard !continuePool.contains(where: { $0.profileId == insight.profileId }) else { continue }

                let isStrong = insight.encounterMinutes >= (Threshold.insightMinEncounterSeconds / 60)
                let isRepeated = insight.score >= 40
                guard isStrong || isRepeated else { continue }

                let age = insight.lastInteractionAt.map { Date().timeIntervalSince($0) }
                let temporal = TemporalResolver.resolve(lastSeenAge: age, signalStrength: insight.confidence, eventDensity: eventDensity)
                guard temporal != .stale else { continue }

                let priority = TemporalResolver.temporalPriority(lastSeenAge: age, signalStrength: insight.confidence)

                insightPool.append(HomeSurfaceItem(
                    section: .insights, profileId: insight.profileId, name: insight.name,
                    avatarUrl: avatarMap[insight.profileId],
                    headline: insight.insightText, subtitle: nil,
                    actionType: insight.isConnected ? .message : .connect,
                    actionLabel: insight.isConnected ? "Message" : "Connect",
                    temporalState: temporal, priority: priority
                ))
            }
        }

        // ── NEXT MOVES: Future-oriented actions ──
        let connectionItems = feedItems.filter { $0.feedType == .connection }
        for item in connectionItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)

            guard !memory.isSuppressed(profileId: actorId, eventId: nil, section: .nextMoves) else { continue }
            // No duplication from Continue
            guard !continuePool.contains(where: { $0.profileId == actorId }) else { continue }

            let hasRecentMessage = messageItems.contains {
                $0.actorProfileId == actorId && ($0.createdAt.map { Date().timeIntervalSince($0) < 3600 } ?? false)
            }
            guard !hasRecentMessage else { continue }

            let strength = signalForConnection(age: age)
            let temporal = TemporalResolver.resolve(lastSeenAge: age, signalStrength: strength, eventDensity: eventDensity)
            guard temporal == .active || temporal == .recent else { continue }

            let priority = TemporalResolver.temporalPriority(lastSeenAge: age, signalStrength: strength)
            guard priority >= Threshold.nextMoveMinPriority else { continue }

            let name = firstName(item.metadata?.actorName ?? "Someone")
            nextMovePool.append(HomeSurfaceItem(
                section: .nextMoves, profileId: actorId, name: name,
                avatarUrl: avatarMap[actorId],
                headline: "Follow up with \(name)",
                subtitle: item.metadata?.eventName.map { "Met at \($0)" },
                actionType: .followUp, actionLabel: "Message",
                temporalState: temporal, priority: priority
            ))
        }

        // Event re-entry suggestion
        if !isAtEvent, let lastEventName = eventName {
            if !memory.isSuppressed(profileId: nil, eventId: eventId, section: .nextMoves) {
                nextMovePool.append(HomeSurfaceItem(
                    section: .nextMoves, profileId: nil, name: lastEventName,
                    headline: "Jump back into \(lastEventName)",
                    actionType: .jumpBack, actionLabel: "Join",
                    temporalState: .recent, priority: 0.1,
                    eventId: eventId, eventName: lastEventName
                ))
            }
        }

        // ── Apply caps and sort ──
        continueItems = Array(continuePool.sorted { $0.priority > $1.priority }.prefix(Cap.continue))
        insightItems = Array(insightPool.sorted { $0.priority > $1.priority }.prefix(Cap.insights))
        nextMoveItems = Array(nextMovePool.sorted { $0.priority > $1.priority }.prefix(Cap.nextMoves))

        lastRefresh = Date()

        #if DEBUG
        print("[Surface] ✅ Built: continue=\(continueItems.count) insights=\(insightItems.count) nextMoves=\(nextMoveItems.count)")
        #endif
    }

    // MARK: - Context Line Generator

    /// Generates human, socially meaningful single-line context.
    private func contextLine(eventName: String?, minutes: Int = 0, verb: String? = nil) -> String? {
        var parts: [String] = []

        if let v = verb {
            if minutes >= 5 {
                parts.append("You spent a few minutes together")
            } else if minutes >= 1 {
                parts.append(v)
            } else {
                parts.append(v + " earlier")
            }
        }

        if let event = eventName, !event.isEmpty {
            if parts.isEmpty {
                parts.append("Also here at \(event)")
            } else {
                parts.append(event)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Signal Strength Helpers

    private func signalForMessage(age: TimeInterval) -> Double {
        if age < 60    { return 1.0 }
        if age < 300   { return 0.8 }
        if age < 600   { return 0.6 }
        if age < 3600  { return 0.3 }
        return 0.1
    }

    private func signalForEncounter(overlapSeconds: Int) -> Double {
        if overlapSeconds >= 900 { return 1.0 }
        if overlapSeconds >= 300 { return 0.7 }
        if overlapSeconds >= 60  { return 0.4 }
        if overlapSeconds >= 30  { return 0.2 }
        return 0.1
    }

    private func signalForConnection(age: TimeInterval) -> Double {
        if age < 3600   { return 0.8 }
        if age < 21600  { return 0.5 }
        if age < 86400  { return 0.3 }
        return 0.1
    }

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    // MARK: - Data Helpers

    private func buildEncounterMap(myId: UUID, eventId: UUID?) -> [UUID: Encounter] {
        var map: [UUID: Encounter] = [:]
        for (profileId, tracker) in EncounterService.shared.activeEncounters {
            map[profileId] = Encounter(
                id: UUID(), eventId: eventId, profileA: myId, profileB: profileId,
                firstSeenAt: tracker.firstSeen, lastSeenAt: tracker.lastSeen,
                overlapSeconds: tracker.totalSeconds,
                confidence: min(1.0, Double(tracker.totalSeconds) / 300.0)
            )
        }
        return map
    }

    private func buildMessageTimeMap(myId: UUID) async -> [UUID: Date] {
        var map: [UUID: Date] = [:]
        for convo in MessagingService.shared.conversations {
            let otherId = convo.otherParticipant(for: myId)
            if let ts = convo.createdAt { map[otherId] = ts }
        }
        return map
    }
}
