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
            let hasSessionEncounter =
                sessionEncounters[rel.profileId] != nil ||
                localSignals[rel.profileId] != nil

            let touchedDuringSession = relationshipTouchedDuringSession(
                rel,
                sessionStart: inferredSessionStart
            )

            let hasEventContext = rel.eventContexts.contains(eventName)

            return rel.profileId != myId &&
                (
                    hasSessionEncounter ||
                    touchedDuringSession ||
                    hasEventContext
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
            strongest: strongest
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
            strongest: strongest,
            connectedIds: connectedIds,
            myInterests: myInterests,
            eventName: eventName
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
        strongest: ProfileSnapshot?
    ) -> [KeyPerson] {
        var results: [KeyPerson] = []
        var seenIds: Set<UUID> = []

        // Ensure strongest interaction can appear in key people if it clears a quality bar.
        if let strongestId = strongest?.id,
           let strongestSignal = personSignals.first(where: { $0.relationship.profileId == strongestId }),
           passesMeaningfulThreshold(strongestSignal) {
            results.append(makeKeyPerson(from: strongestSignal))
            seenIds.insert(strongestId)
        }

        for signal in personSignals.sorted(by: { $0.score > $1.score }) {
            guard !seenIds.contains(signal.relationship.profileId) else { continue }
            guard passesMeaningfulThreshold(signal) else { continue }
            results.append(makeKeyPerson(from: signal))
            seenIds.insert(signal.relationship.profileId)
            if results.count >= 3 { break }
        }

        return results
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
        strongest: ProfileSnapshot?,
        connectedIds: Set<UUID>,
        myInterests: Set<String>,
        eventName: String
    ) -> [FollowUpSuggestion] {
        var suggestions: [FollowUpSuggestion] = []
        var addedIds: Set<UUID> = []

        if let strongestId = strongest?.id,
           let strongestSignal = personSignals.first(where: { $0.relationship.profileId == strongestId }),
           let strongestSuggestion = groundedSuggestion(for: strongestSignal, eventName: eventName, connectedIds: connectedIds, myInterests: myInterests, preferStrongestLanguage: true) {
            suggestions.append(strongestSuggestion)
            addedIds.insert(strongestId)
        }

        let candidates = personSignals
            .sorted { $0.score > $1.score }

        for signal in candidates.prefix(5) {
            guard !addedIds.contains(signal.relationship.profileId) else { continue }
            guard let suggestion = groundedSuggestion(for: signal, eventName: eventName, connectedIds: connectedIds, myInterests: myInterests, preferStrongestLanguage: false) else {
                continue
            }
            suggestions.append(suggestion)
            addedIds.insert(signal.relationship.profileId)
            if suggestions.count >= 3 { break }
        }

        return suggestions
    }

    private static func groundedSuggestion(
        for signal: PersonSignal,
        eventName: String,
        connectedIds: Set<UUID>,
        myInterests: Set<String>,
        preferStrongestLanguage: Bool
    ) -> FollowUpSuggestion? {
        guard hasGroundedFollowUpEvidence(signal) else { return nil }

        let rel = signal.relationship
        let isConnected = connectedIds.contains(rel.profileId) || rel.connectionStatus == .accepted
        let sharedInterests = Set(rel.sharedInterests.map { $0.lowercased() }).intersection(myInterests)

        let type: FollowUpSuggestion.SuggestionType
        let reason: String
        let confidence: Double

        if isConnected && !rel.hasConversation {
            type = .message
            if signal.hasConfirmedPresence {
                reason = preferStrongestLanguage
                    ? "Message \(rel.name): strongest interaction with confirmed shared live presence"
                    : "Message \(rel.name): confirmed shared live presence and a fresh connection from \(eventName)"
            } else {
                reason = "Message \(rel.name): you connected and repeatedly overlapped during \(eventName)"
            }
            confidence = 0.9
        } else if signal.hasConfirmedPresence && (signal.encounterCount >= 2 || signal.totalSeconds >= 120) {
            type = .followUp
            let mins = signal.totalSeconds / 60
            reason = mins > 0
                ? "Follow up with \(rel.name): confirmed shared presence with \(mins) min overlap"
                : "Follow up with \(rel.name): confirmed shared presence across multiple encounters"
            confidence = 0.84
        } else if signal.encounterCount >= 2 && signal.totalSeconds >= 90 {
            type = .meetNextTime
            let mins = signal.totalSeconds / 60
            reason = mins > 0
                ? "Reconnect with \(rel.name) next time: repeated overlap (\(mins) min) during \(eventName)"
                : "Reconnect with \(rel.name) next time: repeated overlap during \(eventName)"
            confidence = 0.76
        } else if isConnected && signal.totalSeconds >= 60 && !sharedInterests.isEmpty {
            type = .message
            let topic = sharedInterests.first ?? "shared interests"
            reason = "Message \(rel.name) about \(topic): connected profile with strong session evidence"
            confidence = 0.72
        } else {
            return nil
        }

        let profile = ProfileSnapshot(
            id: rel.profileId,
            name: rel.name,
            avatarUrl: rel.avatarUrl,
            contextLine: rel.whyLine
        )

        return FollowUpSuggestion(
            id: rel.profileId,
            type: type,
            targetProfile: profile,
            reason: reason,
            confidence: min(confidence, 1.0)
        )
    }

    private static func hasGroundedFollowUpEvidence(_ signal: PersonSignal) -> Bool {
        let repeatedOverlap = signal.encounterCount >= 2 && signal.totalSeconds >= 90
        let confirmedPresence = signal.hasConfirmedPresence && (signal.sessionSeconds >= 45 || signal.localSeconds >= 45)
        let activeSharedContext = signal.hasSharedContext && signal.seenRecently && signal.totalSeconds >= 60
        return repeatedOverlap || confirmedPresence || activeSharedContext
    }

    private static func passesMeaningfulThreshold(_ signal: PersonSignal) -> Bool {
        if signal.hasConfirmedPresence { return true }
        if signal.totalSeconds >= 120 { return true }
        if signal.encounterCount >= 2 && signal.totalSeconds >= 60 { return true }
        if signal.isConnected && signal.totalSeconds >= 60 { return true }
        return false
    }

    private static func makeKeyPerson(from signal: PersonSignal) -> KeyPerson {
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
