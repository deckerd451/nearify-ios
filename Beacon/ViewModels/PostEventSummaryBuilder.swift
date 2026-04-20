import Foundation

/// Builds a PostEventSummary from existing service state.
/// No new backend calls — reads from RelationshipMemory, FeedService,
/// EncounterService, AttendeeStateResolver, EventContextService, and LocalEncounterStore.
///
/// Called once when the user leaves an event or enters dormant state.
/// The result is cached and displayed on the Home screen.
@MainActor
enum PostEventSummaryBuilder {

    private struct LocalEncounterSignal {
        var totalSeconds: Int = 0
        var fragmentCount: Int = 0
        var maxConfidence: Double = 0
    }

    private struct PersonSignal {
        let relationship: RelationshipMemory
        let totalSeconds: Int
        let sessionSeconds: Int
        let localSeconds: Int
        let encounterCount: Int
        let isConnected: Bool
        let hasConversation: Bool
        let hasConfirmedPresence: Bool
        let hasSharedContext: Bool
        let seenRecently: Bool

        var score: Double {
            var result = Double(totalSeconds) / 60.0 * 2.0
            result += Double(encounterCount) * 1.8
            if hasConfirmedPresence { result += 6.0 }
            if isConnected { result += 5.0 }
            if seenRecently { result += 3.0 }
            if hasSharedContext { result += 2.0 }
            if relationship.needsFollowUp { result += 2.0 }
            return result
        }

        var signalTier: KeyPerson.SignalTier {
            if hasConfirmedPresence || (totalSeconds >= 240 && encounterCount >= 2) || isConnected {
                return .high
            }
            if totalSeconds >= 60 || encounterCount >= 2 || hasSharedContext {
                return .medium
            }
            return .low
        }
    }

    /// Builds a summary for the most recent event session.
    /// `eventName`: the event the user just left or went dormant from.
    /// `encounters`: the active encounter trackers from the session (may be empty if already flushed).
    static func build(
        eventName: String,
        eventId: UUID?,
        sessionStartedAt: Date?,
        sessionEncounters: [UUID: EncounterTracker] = [:]
    ) -> PostEventSummary {
        let now = Date()
        let relationships = RelationshipMemoryService.shared.relationships
        let feedItems = FeedService.shared.feedItems
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myId = AuthService.shared.currentUser?.id
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })

        let localEncounters = eventId.map { LocalEncounterStore.shared.encounters(forEvent: $0) } ?? []
        let localSignals = buildLocalEncounterSignals(localEncounters)
        let inferredSessionStart = inferSessionStart(
            explicitSessionStart: sessionStartedAt,
            sessionEncounters: sessionEncounters,
            localEncounters: localEncounters,
            now: now
        )

        // ── Gather event-scoped data ──
        let eventRelationships = relationships.filter { rel in
            let hasSessionEncounter = sessionEncounters[rel.profileId] != nil || localSignals[rel.profileId] != nil
            let touchedDuringSession = relationshipTouchedDuringSession(rel, sessionStart: inferredSessionStart)
            let hasEventContext = rel.eventContexts.contains(eventName)
            rel.profileId != myId && (
                hasSessionEncounter
                || (hasEventContext && touchedDuringSession)
            )
        }

        // Recent connections made during this event
        let recentConnectionIds = Set(
            feedItems
                .filter { item in
                    guard item.feedType == .connection else { return false }
                    guard item.eventId == eventId else { return false }
                    if let created = item.createdAt {
                        return created >= inferredSessionStart
                    }
                    return true
                }
                .compactMap { $0.actorProfileId ?? $0.targetProfileId }
                .filter { $0 != myId }
        )

        // Session-scoped people met (encountered, connected, or touched in-session)
        let sessionEncounterIds = Set(sessionEncounters.keys)
        let localEncounterIds = Set(localSignals.keys)
        var metIds = sessionEncounterIds
        metIds.formUnion(localEncounterIds)
        metIds.formUnion(recentConnectionIds)
        metIds.formUnion(eventRelationships.map(\.profileId))

        let personSignals = buildPersonSignals(
            eventRelationships: eventRelationships,
            sessionEncounters: sessionEncounters,
            localSignals: localSignals,
            connectedIds: connectedIds,
            eventName: eventName,
            now: now
        )

        // ── 1. Strongest Interaction ──
        let strongest = resolveStrongestInteraction(
            personSignals: personSignals,
            eventName: eventName
        )

        // ── 2. Key People ──
        let keyPeople = buildKeyPeople(
            personSignals: personSignals,
            excludeIds: Set([strongest?.id].compactMap { $0 })
        )

        // ── 3. Recent Connections ──
        let recentConnections: [ProfileSnapshot] = eventRelationships
            .filter { recentConnectionIds.contains($0.profileId) || $0.connectionStatus == .accepted }
            .filter { $0.profileId != strongest?.id }
            .prefix(3)
            .map { rel in
                ProfileSnapshot(
                    id: rel.profileId,
                    name: rel.name,
                    avatarUrl: rel.avatarUrl,
                    contextLine: connectionContextLine(rel, eventName: eventName)
                )
            }

        // ── 4. Missed Connections ──
        let missedConnections: [ProfileSnapshot] = personSignals
            .filter { signal in
                let notConnected = signal.relationship.connectionStatus == .none
                let notInRecent = !recentConnectionIds.contains(signal.relationship.profileId)
                let notStrongest = signal.relationship.profileId != strongest?.id
                return signal.totalSeconds >= 120 && signal.encounterCount >= 2 && notConnected && notInRecent && notStrongest
            }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { signal in
                let mins = signal.totalSeconds / 60
                return ProfileSnapshot(
                    id: signal.relationship.profileId,
                    name: signal.relationship.name,
                    avatarUrl: signal.relationship.avatarUrl,
                    contextLine: mins > 0 ? "Repeated overlap (\(mins) min) · no connection yet" : "Repeated overlap · no connection yet"
                )
            }

        // ── 5. Follow-Up Suggestions ──
        let suggestions = buildFollowUpSuggestions(
            personSignals: personSignals,
            connectedIds: connectedIds,
            myInterests: myInterests,
            eventName: eventName,
            excludeIds: Set([strongest?.id].compactMap { $0 })
        )

        let snapshot = buildEventSnapshot(
            eventName: eventName,
            personSignals: personSignals,
            eventRelationships: eventRelationships,
            attendedMinutes: resolveAttendedMinutes(now: now)
        )

        let narrative = buildNarrativeWrapUp(
            eventName: eventName,
            strongest: strongest,
            keyPeople: keyPeople,
            suggestions: suggestions,
            missedConnections: missedConnections,
            snapshot: snapshot
        )

        #if DEBUG
        print("[PostEvent] Summary built for \(eventName)")
        print("[PostEvent]   totalPeopleMet: \(metIds.count)")
        print("[PostEvent]   strongest: \(strongest?.name ?? "none")")
        print("[PostEvent]   keyPeople: \(keyPeople.count)")
        print("[PostEvent]   recentConnections: \(recentConnections.count)")
        print("[PostEvent]   missedConnections: \(missedConnections.count)")
        print("[PostEvent]   followUpSuggestions: \(suggestions.count)")
        #endif

        return PostEventSummary(
            eventName: eventName,
            totalPeopleMet: metIds.count,
            snapshot: snapshot,
            keyPeople: keyPeople,
            strongestInteraction: strongest,
            recentConnections: recentConnections,
            missedConnections: missedConnections,
            followUpSuggestions: suggestions,
            narrativeWrapUp: narrative
        )
    }

    // MARK: - Signals

    private static func buildLocalEncounterSignals(_ encounters: [LocalEncounterStore.CapturedEncounter]) -> [UUID: LocalEncounterSignal] {
        var map: [UUID: LocalEncounterSignal] = [:]
        for encounter in encounters {
            guard let profileId = encounter.resolvedProfileId else { continue }
            var existing = map[profileId, default: LocalEncounterSignal()]
            existing.totalSeconds += encounter.duration
            existing.fragmentCount += 1
            existing.maxConfidence = max(existing.maxConfidence, encounter.confidenceScore)
            map[profileId] = existing
        }
        return map
    }

    private static func inferSessionStart(
        explicitSessionStart: Date?,
        sessionEncounters: [UUID: EncounterTracker],
        localEncounters: [LocalEncounterStore.CapturedEncounter],
        now: Date
    ) -> Date {
        if let explicitSessionStart {
            return explicitSessionStart
        }

        let trackerStart = sessionEncounters.values.map(\.firstSeen).min()
        let localStart = localEncounters.map(\.firstSeenAt).min()
        return [trackerStart, localStart].compactMap { $0 }.min() ?? now.addingTimeInterval(-4 * 3600)
    }

    private static func relationshipTouchedDuringSession(_ rel: RelationshipMemory, sessionStart: Date) -> Bool {
        if let lastEncounter = rel.lastEncounterAt, lastEncounter >= sessionStart {
            return true
        }
        if let connectedAt = rel.connectionDate, connectedAt >= sessionStart {
            return true
        }
        if let messagedAt = rel.lastMessageAt, messagedAt >= sessionStart {
            return true
        }
        return false
    }

    private static func buildPersonSignals(
        eventRelationships: [RelationshipMemory],
        sessionEncounters: [UUID: EncounterTracker],
        localSignals: [UUID: LocalEncounterSignal],
        connectedIds: Set<UUID>,
        eventName: String,
        now: Date
    ) -> [PersonSignal] {
        eventRelationships.map { rel in
            let session = sessionEncounters[rel.profileId]
            let local = localSignals[rel.profileId]
            let sessionSeconds = session?.totalSeconds ?? 0
            let localSeconds = local?.totalSeconds ?? 0
            let totalSeconds = max(rel.totalOverlapSeconds, sessionSeconds, localSeconds)
            let repeatedByLocal = (local?.fragmentCount ?? 0) >= 2
            let encounterCount = max(rel.encounterCount, repeatedByLocal ? 2 : 1)
            let isConnected = connectedIds.contains(rel.profileId) || rel.connectionStatus == .accepted
            let hasConversation = rel.hasConversation

            let hasBleSignal = localSeconds >= 45 || (local?.maxConfidence ?? 0) >= 0.65
            let hasBackendSignal = sessionSeconds >= 45 || rel.totalOverlapSeconds >= 45
            let hasConfirmedPresence = hasBleSignal && hasBackendSignal

            let hasSharedContext = rel.eventContexts.contains(eventName)
            let seenRecently: Bool = {
                if let seen = session?.lastSeen {
                    return now.timeIntervalSince(seen) <= 15 * 60
                }
                if let seen = rel.lastEncounterAt {
                    return now.timeIntervalSince(seen) <= 30 * 60
                }
                return false
            }()

            return PersonSignal(
                relationship: rel,
                totalSeconds: totalSeconds,
                sessionSeconds: sessionSeconds,
                localSeconds: localSeconds,
                encounterCount: encounterCount,
                isConnected: isConnected,
                hasConversation: hasConversation,
                hasConfirmedPresence: hasConfirmedPresence,
                hasSharedContext: hasSharedContext,
                seenRecently: seenRecently
            )
        }
    }

    // MARK: - Strongest Interaction

    private static func resolveStrongestInteraction(
        personSignals: [PersonSignal],
        eventName: String
    ) -> ProfileSnapshot? {
        guard let best = personSignals.max(by: { $0.score < $1.score }), best.score > 0 else {
            return nil
        }

        let mins = best.totalSeconds / 60
        let context: String
        if best.hasConfirmedPresence {
            context = mins > 0 ? "\(mins) min confirmed live overlap" : "Confirmed live overlap"
        } else if mins >= 5 {
            context = "\(mins) min together · strongest signal"
        } else if best.encounterCount >= 2 {
            context = "Crossed paths \(best.encounterCount) times at \(eventName)"
        } else {
            context = "Strongest interaction this session"
        }

        return ProfileSnapshot(
            id: best.relationship.profileId,
            name: best.relationship.name,
            avatarUrl: best.relationship.avatarUrl,
            contextLine: context
        )
    }

    // MARK: - Key People

    private static func buildKeyPeople(
        personSignals: [PersonSignal],
        excludeIds: Set<UUID>
    ) -> [KeyPerson] {
        personSignals
            .filter { !excludeIds.contains($0.relationship.profileId) }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { signal in
                let profile = ProfileSnapshot(
                    id: signal.relationship.profileId,
                    name: signal.relationship.name,
                    avatarUrl: signal.relationship.avatarUrl,
                    contextLine: signal.relationship.whyLine
                )

                let reason: String
                if signal.hasConfirmedPresence {
                    reason = "BLE + backend both confirmed shared presence"
                } else if signal.isConnected {
                    reason = signal.hasConversation ? "Connected and already in conversation" : "Connected during event but not messaged yet"
                } else if signal.encounterCount >= 2 {
                    reason = "Repeated overlap across \(signal.encounterCount) encounters"
                } else {
                    let mins = signal.totalSeconds / 60
                    reason = mins > 0 ? "\(mins) min of overlap during the event" : "Shared event context"
                }

                return KeyPerson(
                    id: profile.id,
                    profile: profile,
                    reason: reason,
                    signalTier: signal.signalTier
                )
            }
    }

    // MARK: - Event Snapshot

    private static func buildEventSnapshot(
        eventName: String,
        personSignals: [PersonSignal],
        eventRelationships: [RelationshipMemory],
        attendedMinutes: Int?
    ) -> EventSnapshot {
        let meaningfulCount = personSignals.filter { $0.signalTier != .low }.count
        let highSignalCount = personSignals.filter { $0.signalTier == .high }.count

        let activityLine: String
        if highSignalCount >= 3 {
            activityLine = "High-activity session with multiple strong contacts"
        } else if highSignalCount >= 1 || meaningfulCount >= 3 {
            activityLine = "Steady activity with clear follow-up candidates"
        } else if !eventRelationships.isEmpty {
            activityLine = "Light session with at least one meaningful overlap"
        } else {
            activityLine = "Minimal interaction captured for \(eventName)"
        }

        return EventSnapshot(
            attendedMinutes: attendedMinutes,
            meaningfulPeopleCount: meaningfulCount,
            activityLine: activityLine
        )
    }

    private static func resolveAttendedMinutes(now: Date) -> Int? {
        guard
            let joinedAtString = EventContextService.shared.cachedContext?.joinedAt,
            let joinedAt = ISO8601DateFormatter().date(from: joinedAtString)
        else {
            return nil
        }

        let mins = Int(now.timeIntervalSince(joinedAt) / 60)
        return mins > 0 ? mins : nil
    }

    // MARK: - Connection Context

    private static func connectionContextLine(_ rel: RelationshipMemory, eventName: String) -> String {
        if rel.hasConversation {
            return "Connected · already messaged"
        }
        if rel.connectionDate != nil {
            return "Connected at \(eventName)"
        }
        return "Connected"
    }

    // MARK: - Follow-Up Suggestions

    private static func buildFollowUpSuggestions(
        personSignals: [PersonSignal],
        connectedIds: Set<UUID>,
        myInterests: Set<String>,
        eventName: String,
        excludeIds: Set<UUID>
    ) -> [FollowUpSuggestion] {
        var suggestions: [FollowUpSuggestion] = []

        let candidates = personSignals
            .filter { !excludeIds.contains($0.relationship.profileId) }
            .sorted { $0.score > $1.score }

        for signal in candidates.prefix(5) {
            let rel = signal.relationship
            let isConnected = connectedIds.contains(rel.profileId) || rel.connectionStatus == .accepted
            let sharedInterests = Set(rel.sharedInterests.map { $0.lowercased() }).intersection(myInterests)

            let type: FollowUpSuggestion.SuggestionType
            let reason: String
            let confidence: Double

            if isConnected && !rel.hasConversation {
                type = .message
                if signal.hasConfirmedPresence {
                    reason = "Follow up with \(rel.name) — confirmed shared live presence and new connection"
                } else {
                    reason = "Message \(rel.name) now — you connected at \(eventName)"
                }
                confidence = 0.92
            } else if isConnected && rel.hasConversation {
                type = .followUp
                reason = "Continue with \(rel.name) — this event reinforced an active conversation"
                confidence = 0.66
            } else if signal.totalSeconds >= 180 || signal.encounterCount >= 3 {
                let mins = signal.totalSeconds / 60
                type = .followUp
                if mins > 0 {
                    reason = "Reconnect with \(rel.name): repeated overlap (\(mins) min) without a connection yet"
                } else {
                    reason = "Reconnect with \(rel.name): repeated overlap without a connection yet"
                }
                confidence = min(0.96, 0.65 + Double(signal.encounterCount) * 0.06)
            } else if !sharedInterests.isEmpty {
                let topic = sharedInterests.first ?? "shared interests"
                type = .meetNextTime
                reason = "Follow up on \(topic) with \(rel.name) — clear shared interest signal"
                confidence = 0.58 + Double(sharedInterests.count) * 0.1
            } else {
                continue
            }

            let profile = ProfileSnapshot(
                id: rel.profileId,
                name: rel.name,
                avatarUrl: rel.avatarUrl,
                contextLine: rel.whyLine
            )

            suggestions.append(FollowUpSuggestion(
                id: rel.profileId,
                type: type,
                targetProfile: profile,
                reason: reason,
                confidence: min(confidence, 1.0)
            ))
        }

        return suggestions
    }

    // MARK: - Narrative

    private static func buildNarrativeWrapUp(
        eventName: String,
        strongest: ProfileSnapshot?,
        keyPeople: [KeyPerson],
        suggestions: [FollowUpSuggestion],
        missedConnections: [ProfileSnapshot],
        snapshot: EventSnapshot
    ) -> String {
        var lines: [String] = []

        if let strongest {
            lines.append("At \(eventName), your clearest interaction was with \(strongest.name).")
        }

        if snapshot.meaningfulPeopleCount > 0 {
            lines.append("You had \(snapshot.meaningfulPeopleCount) meaningful contact\(snapshot.meaningfulPeopleCount == 1 ? "" : "s") and \(suggestions.count) concrete follow-up option\(suggestions.count == 1 ? "" : "s").")
        }

        if let topMiss = missedConnections.first {
            lines.append("One missed opportunity: repeated overlap with \(topMiss.name) without a connection.")
        }

        if let highSignal = keyPeople.first(where: { $0.signalTier == .high }) {
            lines.append("Strongest signal category: \(highSignal.reason.lowercased()).")
        }

        return lines.joined(separator: " ")
    }
}
