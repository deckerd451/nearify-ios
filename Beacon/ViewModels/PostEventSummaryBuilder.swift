import Foundation

/// Builds a PostEventSummary from existing service state.
/// No new backend calls — reads from RelationshipMemory, FeedService,
/// EncounterService, and AttendeeStateResolver.
///
/// Called once when the user leaves an event or enters dormant state.
/// The result is cached and displayed on the Home screen.
@MainActor
enum PostEventSummaryBuilder {

    /// Builds a summary for the most recent event session.
    /// `eventName`: the event the user just left or went dormant from.
    /// `encounters`: the active encounter trackers from the session (may be empty if already flushed).
    static func build(
        eventName: String,
        sessionEncounters: [UUID: EncounterTracker] = [:]
    ) -> PostEventSummary {
        let relationships = RelationshipMemoryService.shared.relationships
        let feedItems = FeedService.shared.feedItems
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myId = AuthService.shared.currentUser?.id
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })

        // ── Gather event-scoped data ──

        // People encountered at this event (from feed items + relationships)
        let eventRelationships = relationships.filter { rel in
            rel.profileId != myId && (
                rel.eventContexts.contains(eventName)
                || sessionEncounters[rel.profileId] != nil
            )
        }

        // Recent connections made during this event
        let recentConnectionIds = Set(
            feedItems
                .filter { $0.feedType == .connection && $0.eventId != nil }
                .compactMap { $0.actorProfileId ?? $0.targetProfileId }
                .filter { $0 != myId }
        )

        // All people met (encountered or connected)
        var allMetIds = Set(eventRelationships.map(\.profileId))
        allMetIds.formUnion(recentConnectionIds)

        // ── 1. Strongest Interaction ──
        let strongest = resolveStrongestInteraction(
            relationships: eventRelationships,
            sessionEncounters: sessionEncounters,
            eventName: eventName
        )

        // ── 2. Recent Connections ──
        let recentConnections: [ProfileSnapshot] = eventRelationships
            .filter { recentConnectionIds.contains($0.profileId) || $0.connectionStatus == .accepted }
            .filter { $0.profileId != strongest?.id } // avoid duplicate with strongest
            .prefix(3)
            .map { rel in
                ProfileSnapshot(
                    id: rel.profileId,
                    name: rel.name,
                    avatarUrl: rel.avatarUrl,
                    contextLine: connectionContextLine(rel, eventName: eventName)
                )
            }

        // ── 3. Missed Connections ──
        let missedConnections: [ProfileSnapshot] = eventRelationships
            .filter { rel in
                // High proximity but no connection
                let hasSignificantOverlap = rel.totalOverlapSeconds >= 60
                    || (sessionEncounters[rel.profileId]?.totalSeconds ?? 0) >= 60
                let notConnected = rel.connectionStatus == .none
                let notInRecent = !recentConnectionIds.contains(rel.profileId)
                let notStrongest = rel.profileId != strongest?.id
                return hasSignificantOverlap && notConnected && notInRecent && notStrongest
            }
            .sorted { a, b in
                let aOverlap = max(a.totalOverlapSeconds, sessionEncounters[a.profileId]?.totalSeconds ?? 0)
                let bOverlap = max(b.totalOverlapSeconds, sessionEncounters[b.profileId]?.totalSeconds ?? 0)
                return aOverlap > bOverlap
            }
            .prefix(3)
            .map { rel in
                let overlap = max(rel.totalOverlapSeconds, sessionEncounters[rel.profileId]?.totalSeconds ?? 0)
                let mins = overlap / 60
                return ProfileSnapshot(
                    id: rel.profileId,
                    name: rel.name,
                    avatarUrl: rel.avatarUrl,
                    contextLine: mins > 0 ? "\(mins) min nearby · no connection" : "Nearby · no connection"
                )
            }

        // ── 4. Follow-Up Suggestions ──
        let suggestions = buildFollowUpSuggestions(
            relationships: eventRelationships,
            sessionEncounters: sessionEncounters,
            connectedIds: connectedIds,
            myInterests: myInterests,
            eventName: eventName,
            excludeIds: Set([strongest?.id].compactMap { $0 })
        )

        #if DEBUG
        print("[PostEvent] Summary built for \(eventName)")
        print("[PostEvent]   totalPeopleMet: \(allMetIds.count)")
        print("[PostEvent]   strongest: \(strongest?.name ?? "none")")
        print("[PostEvent]   recentConnections: \(recentConnections.count)")
        print("[PostEvent]   missedConnections: \(missedConnections.count)")
        print("[PostEvent]   followUpSuggestions: \(suggestions.count)")
        #endif

        return PostEventSummary(
            eventName: eventName,
            totalPeopleMet: allMetIds.count,
            strongestInteraction: strongest,
            recentConnections: recentConnections,
            missedConnections: missedConnections,
            followUpSuggestions: suggestions
        )
    }

    // MARK: - Strongest Interaction

    private static func resolveStrongestInteraction(
        relationships: [RelationshipMemory],
        sessionEncounters: [UUID: EncounterTracker],
        eventName: String
    ) -> ProfileSnapshot? {
        // Score by: session encounter time + historical overlap + encounter count
        let scored = relationships.map { rel -> (RelationshipMemory, Int) in
            let sessionTime = sessionEncounters[rel.profileId]?.totalSeconds ?? 0
            let totalTime = max(rel.totalOverlapSeconds, sessionTime)
            let repeatBonus = rel.encounterCount >= 2 ? 120 : 0
            return (rel, totalTime + repeatBonus)
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return nil
        }

        let rel = best.0
        let mins = best.1 / 60
        let context: String
        if mins >= 5 {
            context = "\(mins) min together · strongest signal"
        } else if rel.encounterCount >= 2 {
            context = "Crossed paths \(rel.encounterCount) times"
        } else if mins > 0 {
            context = "\(mins) min nearby"
        } else {
            context = "Strongest interaction"
        }

        return ProfileSnapshot(
            id: rel.profileId,
            name: rel.name,
            avatarUrl: rel.avatarUrl,
            contextLine: context
        )
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
        relationships: [RelationshipMemory],
        sessionEncounters: [UUID: EncounterTracker],
        connectedIds: Set<UUID>,
        myInterests: Set<String>,
        eventName: String,
        excludeIds: Set<UUID>
    ) -> [FollowUpSuggestion] {
        var suggestions: [FollowUpSuggestion] = []

        let candidates = relationships
            .filter { !excludeIds.contains($0.profileId) }
            .sorted { a, b in
                // Priority: recent interaction > high dwell > shared interests
                let aScore = suggestionScore(a, sessionEncounters: sessionEncounters, myInterests: myInterests)
                let bScore = suggestionScore(b, sessionEncounters: sessionEncounters, myInterests: myInterests)
                return aScore > bScore
            }

        for rel in candidates.prefix(5) {
            let isConnected = connectedIds.contains(rel.profileId)
            let sessionTime = sessionEncounters[rel.profileId]?.totalSeconds ?? 0
            let totalTime = max(rel.totalOverlapSeconds, sessionTime)
            let sharedInterests = Set(rel.sharedInterests.map { $0.lowercased() }).intersection(myInterests)

            let type: FollowUpSuggestion.SuggestionType
            let reason: String
            let confidence: Double

            if isConnected && !rel.hasConversation {
                // Connected but never messaged — follow up
                type = .message
                reason = "You connected but haven't messaged yet"
                confidence = 0.9
            } else if isConnected && rel.hasConversation {
                // Already in conversation — lower priority
                type = .followUp
                reason = "Keep the conversation going"
                confidence = 0.6
            } else if totalTime >= 120 {
                // Significant time together but not connected
                let mins = totalTime / 60
                type = .followUp
                reason = "You spent \(mins) min together — worth connecting"
                confidence = min(0.95, Double(totalTime) / 600.0 + 0.5)
            } else if !sharedInterests.isEmpty {
                // Shared interests
                let topic = sharedInterests.first ?? ""
                type = .meetNextTime
                reason = "You both share an interest in \(topic)"
                confidence = 0.5 + Double(sharedInterests.count) * 0.1
            } else if rel.encounterCount >= 2 {
                // Repeated encounters
                type = .followUp
                reason = "You crossed paths \(rel.encounterCount) times"
                confidence = 0.6
            } else {
                continue // Not enough signal
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

    private static func suggestionScore(
        _ rel: RelationshipMemory,
        sessionEncounters: [UUID: EncounterTracker],
        myInterests: Set<String>
    ) -> Double {
        var score: Double = 0

        // Recent interaction (session encounter time)
        let sessionTime = sessionEncounters[rel.profileId]?.totalSeconds ?? 0
        score += Double(sessionTime) / 60.0 * 3.0 // 3 points per minute

        // Historical dwell time
        score += Double(rel.totalOverlapSeconds) / 60.0 * 1.5

        // Shared interests
        let shared = Set(rel.sharedInterests.map { $0.lowercased() }).intersection(myInterests)
        score += Double(shared.count) * 2.0

        // Connection status bonus
        if rel.connectionStatus == .accepted { score += 5.0 }

        // Needs follow-up bonus
        if rel.needsFollowUp { score += 4.0 }

        // Repeat encounters
        score += Double(rel.encounterCount) * 2.0

        return score
    }
}
