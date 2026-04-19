import Foundation

// MARK: - Event Relevance

enum RelevanceMode: String {
    case reinforcement = "reinforcement"
    case expansion = "expansion"
}

struct EventRelevance {
    let reason: String
    let mode: RelevanceMode
    let familiarityScore: Double
    let expansionScore: Double
}

// MARK: - Event Relevance Scorer

/// Computes familiarity and expansion relevance for Explore events.
/// Uses existing data only — no new backend queries.
@MainActor
struct EventRelevanceScorer {

    /// Computes relevance for a single event.
    /// Returns nil if no meaningful signal exists.
    static func score(event: ExploreEvent) -> EventRelevance? {
        let relationships = RelationshipMemoryService.shared.relationships
        let feedItems = FeedService.shared.feedItems
        let user = AuthService.shared.currentUser

        let myInterests = Set((user?.interests ?? []).map { $0.lowercased() })
        let mySkills = Set((user?.skills ?? []).map { $0.lowercased() })

        // ── FAMILIARITY SCORE ──
        var familiarity: Double = 0
        var familiarReasons: [String] = []

        // People tied to this event via relationship memory
        let eventName = event.name
        let peopleFromEvent = relationships.filter { r in
            r.eventContexts.contains(where: { $0.lowercased() == eventName.lowercased() })
        }

        if peopleFromEvent.count >= 1 {
            familiarity += Double(peopleFromEvent.count) * 2.0
            if peopleFromEvent.count == 1 {
                familiarReasons.append("You met someone here before")
            } else {
                familiarReasons.append("You met \(peopleFromEvent.count) people here before")
            }
        }

        // Strong interactions at this event
        let strongInteractions = peopleFromEvent.filter { $0.totalOverlapSeconds >= 300 }
        if !strongInteractions.isEmpty {
            familiarity += Double(strongInteractions.count) * 3.0
            familiarReasons.append("You had strong conversations here")
        }

        // Connected people tied to this event
        let connectedFromEvent = peopleFromEvent.filter { $0.connectionStatus == .accepted }
        if connectedFromEvent.count >= 2 {
            familiarity += Double(connectedFromEvent.count) * 2.0
            familiarReasons.append("\(connectedFromEvent.count) people you know attended")
        } else if connectedFromEvent.count == 1 {
            familiarity += 2.0
        }

        // Feed items referencing this event
        let eventFeedItems = feedItems.filter { item in
            item.metadata?.eventName?.lowercased() == eventName.lowercased()
        }
        if eventFeedItems.count >= 2 {
            familiarity += 1.0
        }

        // ── EXPANSION SCORE ──
        // Only evaluate expansion when familiarity is not already strong.
        // This ensures familiar events dominate when appropriate.
        var expansion: Double = 0
        var expansionReasons: [String] = []

        let eventText = tokenize(event.name).union(tokenize(event.eventDescription ?? ""))
        let interestOverlap = myInterests.filter { eventText.contains($0) }
        let skillOverlap = mySkills.filter { eventText.contains($0) }
        let totalOverlap = interestOverlap.count + skillOverlap.count
        let wasAttended = !peopleFromEvent.isEmpty || !eventFeedItems.isEmpty

        if familiarity < 2.0 {
            // Interest/skill overlap with event text
            if totalOverlap >= 2 {
                expansion += Double(totalOverlap) * 2.5
                let topics = Array(interestOverlap.union(skillOverlap)).prefix(2).joined(separator: " and ")
                expansionReasons.append("Expands your interest in \(topics)")
            } else if totalOverlap == 1 {
                expansion += 2.0
                let topic = interestOverlap.first ?? skillOverlap.first ?? ""
                expansionReasons.append("Builds on your interest in \(topic)")
            }

            // Not previously attended = novelty bonus
            if !wasAttended {
                expansion += 3.0
                if expansionReasons.isEmpty {
                    expansionReasons.append("New event worth exploring")
                }
            }

            // New direction: matches interests but zero familiarity
            if totalOverlap >= 1 && familiarity == 0 {
                expansion += 2.5
                if !expansionReasons.contains(where: { $0.hasPrefix("Expands") || $0.hasPrefix("Builds") }) {
                    expansionReasons.append("New direction based on your interests")
                }
            }

            // Low relationship density + some overlap = fresh crowd
            if peopleFromEvent.isEmpty && totalOverlap >= 1 {
                expansion += 2.0
            }

            // Weak overlap fallback — expansion triggered but no interest match
            if totalOverlap == 0 && expansion > 0 && expansionReasons.isEmpty {
                expansionReasons.append("Different from your usual events — worth exploring")
            }
        }

        #if DEBUG
        print("[EventRelevance] Event: \(event.name)")
        print("[EventRelevance] familiarityScore: \(familiarity)")
        print("[EventRelevance] expansionScore: \(expansion)")
        #endif

        // ── SELECT BEST REASON ──
        // If both are zero, no meaningful signal
        guard familiarity > 0 || expansion > 0 else {
            #if DEBUG
            print("[EventRelevance] No signal — skipping")
            #endif
            return nil
        }

        // Pick the winning mode
        // Slight bias toward expansion when scores are close (avoid echo chamber)
        let mode: RelevanceMode
        let reason: String

        if familiarity > expansion * 1.3 {
            // Clear familiarity winner
            mode = .reinforcement
            reason = familiarReasons.first ?? "You have history here"
        } else if expansion > 0 {
            // Expansion wins or is close enough
            mode = .expansion
            reason = expansionReasons.first ?? "Worth exploring"
        } else {
            mode = .reinforcement
            reason = familiarReasons.first ?? "You have history here"
        }

        #if DEBUG
        print("[EventRelevance] Reason selected: \(reason)")
        print("[EventRelevance] Mode: \(mode.rawValue)")
        #endif

        return EventRelevance(
            reason: reason,
            mode: mode,
            familiarityScore: familiarity,
            expansionScore: expansion
        )
    }

    // MARK: - Helpers

    /// Tokenizes text into lowercase words for matching.
    private static func tokenize(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Set(words)
    }
}
