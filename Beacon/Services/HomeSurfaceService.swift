import Foundation
import Combine

/// Maslow-aligned, time-aware intelligence surface.
/// Answers: What matters right now? What should I do next? What should I not lose?
///
/// Sections rendered in strict order: CONTINUE → INSIGHTS → NEXT MOVES.
/// Items are suppressed when timing + signal thresholds are not met.
@MainActor
final class HomeSurfaceService: ObservableObject {

    static let shared = HomeSurfaceService()

    @Published private(set) var continueItems: [HomeSurfaceItem] = []
    @Published private(set) var insightItems: [HomeSurfaceItem] = []
    @Published private(set) var nextMoveItems: [HomeSurfaceItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    private var isRefreshing = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Section Caps
    private enum Cap {
        static let `continue` = 3
        static let insights = 2
        static let nextMoves = 2
    }

    // MARK: - Signal Thresholds
    private enum Threshold {
        static let continueMinPriority: Double = 0.05
        static let insightMinEncounterSeconds: Int = 120   // 2 min minimum for insight
        static let insightMinEncounterCount: Int = 2       // or repeated encounters
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

    // MARK: - Surface Builder

    private func buildSurface() async {
        isLoading = true
        defer { isLoading = false }

        guard let myId = AuthService.shared.currentUser?.id else { return }

        // Gather all signals in parallel
        let feedItems = FeedService.shared.feedItems
        let activeEncounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let isAtEvent = EventJoinService.shared.isEventJoined
        let eventName = EventJoinService.shared.currentEventName
        let eventIdStr = EventJoinService.shared.currentEventID
        let eventId = eventIdStr.flatMap { UUID(uuidString: $0) }
        let attendees = EventAttendeesService.shared.attendees

        // Compute event density (normalized 0–1)
        let eventDensity = min(Double(attendees.count) / 50.0, 1.0)

        var continuePool: [HomeSurfaceItem] = []
        var insightPool: [HomeSurfaceItem] = []
        var nextMovePool: [HomeSurfaceItem] = []

        // ── CONTINUE: Unread messages ──
        let messageItems = feedItems.filter { $0.feedType == .message }
        for item in messageItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)

            let signalStrength = signalForMessage(age: age)
            let temporal = TemporalResolver.resolve(
                lastSeenAge: age,
                signalStrength: signalStrength,
                eventDensity: eventDensity
            )

            // Only IMMEDIATE or LIVE messages belong in CONTINUE
            guard temporal == .immediate || temporal == .live else { continue }

            let priority = TemporalResolver.temporalPriority(
                lastSeenAge: age,
                signalStrength: signalStrength
            )
            guard priority >= Threshold.continueMinPriority else { continue }

            let name = firstName(item.metadata?.actorName ?? "Someone")
            continuePool.append(HomeSurfaceItem(
                section: .continue,
                profileId: actorId,
                name: name,
                headline: "Reply to \(name)",
                subtitle: item.metadata?.messagePreview,
                actionType: .reply,
                actionLabel: "Reply",
                temporalState: temporal,
                priority: priority + 0.5, // Messages get urgency boost
                conversationId: item.metadata?.conversationId.flatMap { UUID(uuidString: $0) }
            ))
        }

        // ── CONTINUE: Immediate/live encounters (nearby now) ──
        if isAtEvent {
            for (profileId, tracker) in activeEncounters {
                guard profileId != myId else { continue }
                let age = Date().timeIntervalSince(tracker.lastSeen)
                let overlapStrength = signalForEncounter(overlapSeconds: tracker.totalSeconds)
                let temporal = TemporalResolver.resolve(
                    lastSeenAge: age,
                    signalStrength: overlapStrength,
                    eventDensity: eventDensity
                )

                guard temporal == .immediate || temporal == .live else { continue }

                let priority = TemporalResolver.temporalPriority(
                    lastSeenAge: age,
                    signalStrength: overlapStrength
                )
                guard priority >= Threshold.continueMinPriority else { continue }

                let attendee = attendees.first(where: { $0.id == profileId })
                let name = firstName(attendee?.name ?? "Someone")
                let isConnected = connectedIds.contains(profileId)

                if temporal == .immediate {
                    // "Doug is nearby — go say hi"
                    // ALWAYS routes to find-attendee for live proximity, regardless of connection
                    continuePool.append(HomeSurfaceItem(
                        section: .continue,
                        profileId: profileId,
                        name: name,
                        headline: "\(name) is nearby — go say hi",
                        subtitle: eventName,
                        actionType: .findAttendee,
                        actionLabel: isConnected ? "Go say hi" : "Find",
                        temporalState: temporal,
                        priority: priority + 0.3,
                        eventId: eventId,
                        eventName: eventName,
                        isFind: true
                    ))
                } else {
                    // LIVE: "Find Descartes — you were just near them"
                    continuePool.append(HomeSurfaceItem(
                        section: .continue,
                        profileId: profileId,
                        name: name,
                        headline: "Find \(name) — you were just near them",
                        subtitle: eventName,
                        actionType: .findAttendee,
                        actionLabel: "Find",
                        temporalState: temporal,
                        priority: priority,
                        eventId: eventId,
                        eventName: eventName,
                        isFind: true
                    ))
                }
            }
        }

        // ── CONTINUE: Very recent strong encounters from DB ──
        let encounterItems = feedItems.filter { $0.feedType == .encounter }
        for item in encounterItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            // Skip if already in active encounters (avoid duplicates)
            guard activeEncounters[actorId] == nil else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)
            let overlap = item.metadata?.overlapSeconds ?? 0
            let strength = signalForEncounter(overlapSeconds: overlap)
            let temporal = TemporalResolver.resolve(
                lastSeenAge: age,
                signalStrength: strength,
                eventDensity: eventDensity
            )

            // Only very recent strong encounters in CONTINUE
            guard temporal == .immediate || temporal == .live else { continue }
            guard strength >= 0.3 else { continue }

            let priority = TemporalResolver.temporalPriority(
                lastSeenAge: age,
                signalStrength: strength
            )
            let name = firstName(item.metadata?.actorName ?? "Someone")
            let isConnected = connectedIds.contains(actorId)

            continuePool.append(HomeSurfaceItem(
                section: .continue,
                profileId: actorId,
                name: name,
                headline: isConnected ? "\(name) is nearby — go say hi" : "Find \(name) — you were just near them",
                subtitle: item.metadata?.eventName,
                actionType: .findAttendee,
                actionLabel: isConnected ? "Go say hi" : "Find",
                temporalState: temporal,
                priority: priority,
                eventId: item.eventId,
                eventName: item.metadata?.eventName,
                isFind: true
            ))
        }

        // ── INSIGHTS: Non-obvious patterns from real interaction data ──
        let viewerProfile = AuthService.shared.currentUser
        if isAtEvent {
            let encounterMap = buildEncounterMap(myId: myId, eventId: eventId)
            let lastMessageTimes = await buildMessageTimeMap(myId: myId)

            let signals = InteractionInsightService.shared.buildSignals(
                attendees: attendees,
                encounters: encounterMap,
                connectedIds: connectedIds,
                lastMessageTimes: lastMessageTimes,
                viewerProfile: viewerProfile,
                myId: myId
            )
            let insights = InteractionInsightService.shared.generateInsights(from: signals)

            for insight in insights {
                // INSIGHT QUALITY RULE: skip weak/trivial insights
                guard insight.confidence >= 0.5 else { continue }
                guard insight.encounterMinutes >= 2 || insight.sharedInterests.count >= 2 else { continue }

                // Must be based on strong or repeated signal
                let isStrong = insight.encounterMinutes >= (Threshold.insightMinEncounterSeconds / 60)
                let isRepeated = insight.score >= 40
                guard isStrong || isRepeated else { continue }

                let age = insight.lastInteractionAt.map { Date().timeIntervalSince($0) }
                let temporal = TemporalResolver.resolve(
                    lastSeenAge: age,
                    signalStrength: insight.confidence,
                    eventDensity: eventDensity
                )
                // Insights can be active or recent, not stale
                guard temporal != .stale else { continue }

                let priority = TemporalResolver.temporalPriority(
                    lastSeenAge: age,
                    signalStrength: insight.confidence
                )

                insightPool.append(HomeSurfaceItem(
                    section: .insights,
                    profileId: insight.profileId,
                    name: insight.name,
                    headline: insight.insightText,
                    subtitle: nil,
                    actionType: insight.isConnected ? .message : .connect,
                    actionLabel: insight.isConnected ? "Message" : "Connect",
                    temporalState: temporal,
                    priority: priority
                ))
            }
        }

        // ── NEXT MOVES: Future-oriented actions ──
        // Follow-up gaps (connected but no recent message)
        let connectionItems = feedItems.filter { $0.feedType == .connection }
        for item in connectionItems {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard let ts = item.createdAt else { continue }
            let age = Date().timeIntervalSince(ts)

            // Skip if already in CONTINUE (active conversation)
            let isInContinue = continuePool.contains { $0.profileId == actorId }
            guard !isInContinue else { continue }

            // Skip if there's a recent message (that's CONTINUE territory)
            let hasRecentMessage = messageItems.contains {
                $0.actorProfileId == actorId && ($0.createdAt.map { Date().timeIntervalSince($0) < 3600 } ?? false)
            }
            guard !hasRecentMessage else { continue }

            let strength = signalForConnection(age: age)
            let temporal = TemporalResolver.resolve(
                lastSeenAge: age,
                signalStrength: strength,
                eventDensity: eventDensity
            )
            // NEXT MOVES: active or recent, not stale
            guard temporal == .active || temporal == .recent else { continue }

            let priority = TemporalResolver.temporalPriority(
                lastSeenAge: age,
                signalStrength: strength
            )
            guard priority >= Threshold.nextMoveMinPriority else { continue }

            let name = firstName(item.metadata?.actorName ?? "Someone")
            nextMovePool.append(HomeSurfaceItem(
                section: .nextMoves,
                profileId: actorId,
                name: name,
                headline: "Follow up with \(name)",
                subtitle: item.metadata?.eventName.map { "Met at \($0)" },
                actionType: .followUp,
                actionLabel: "Message",
                temporalState: temporal,
                priority: priority
            ))
        }

        // Event re-entry suggestion
        if !isAtEvent, let lastEventName = eventName {
            nextMovePool.append(HomeSurfaceItem(
                section: .nextMoves,
                profileId: nil,
                name: lastEventName,
                headline: "Jump back into \(lastEventName)",
                subtitle: nil,
                actionType: .jumpBack,
                actionLabel: "Join",
                temporalState: .recent,
                priority: 0.1,
                eventId: eventId,
                eventName: lastEventName
            ))
        }

        // ── Apply caps and sort by priority ──
        continueItems = Array(continuePool.sorted { $0.priority > $1.priority }.prefix(Cap.continue))
        insightItems = Array(insightPool.sorted { $0.priority > $1.priority }.prefix(Cap.insights))
        nextMoveItems = Array(nextMovePool.sorted { $0.priority > $1.priority }.prefix(Cap.nextMoves))

        lastRefresh = Date()

        #if DEBUG
        print("[Surface] ✅ Built: continue=\(continueItems.count) insights=\(insightItems.count) nextMoves=\(nextMoveItems.count)")
        #endif
    }

    // MARK: - Signal Strength Helpers

    /// Normalized signal strength for a message based on age.
    private func signalForMessage(age: TimeInterval) -> Double {
        if age < 60    { return 1.0 }
        if age < 300   { return 0.8 }
        if age < 600   { return 0.6 }
        if age < 3600  { return 0.3 }
        return 0.1
    }

    /// Normalized signal strength for an encounter based on overlap.
    private func signalForEncounter(overlapSeconds: Int) -> Double {
        if overlapSeconds >= 900 { return 1.0 }
        if overlapSeconds >= 300 { return 0.7 }
        if overlapSeconds >= 60  { return 0.4 }
        if overlapSeconds >= 30  { return 0.2 }
        return 0.1
    }

    /// Normalized signal strength for a connection based on age.
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

        // In-memory tracker data (most current)
        for (profileId, tracker) in EncounterService.shared.activeEncounters {
            map[profileId] = Encounter(
                id: UUID(),
                eventId: eventId,
                profileA: myId,
                profileB: profileId,
                firstSeenAt: tracker.firstSeen,
                lastSeenAt: tracker.lastSeen,
                overlapSeconds: tracker.totalSeconds,
                confidence: min(1.0, Double(tracker.totalSeconds) / 300.0)
            )
        }

        return map
    }

    private func buildMessageTimeMap(myId: UUID) async -> [UUID: Date] {
        var map: [UUID: Date] = [:]
        let conversations = MessagingService.shared.conversations
        for convo in conversations {
            let otherId = convo.otherParticipant(for: myId)
            // Use conversation created_at as proxy if no messages loaded
            if let ts = convo.createdAt {
                map[otherId] = ts
            }
        }
        return map
    }
}
