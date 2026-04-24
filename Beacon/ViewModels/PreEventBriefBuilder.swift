import Foundation

/// Computes a lightweight pre-event brief from existing intelligence sources.
/// No new backend calls and no schema changes.
@MainActor
enum PreEventBriefBuilder {

    struct Brief {
        let goalLine: String
        let priorityPeople: [PriorityPerson]
        let whyLine: String
        let conversationStarters: [String]
        let missedOpportunityLine: String?
    }

    struct PriorityPerson: Identifiable {
        let id: UUID
        let name: String
        let avatarUrl: String?
        let reason: String
    }

    /// Builds a brief for the current joined event state.
    static func build(eventId: UUID, eventName: String) -> Brief {
        let relationships = RelationshipMemoryService.shared.relationships
        let myId = AuthService.shared.currentUser?.id
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })
        let intentPrimary = EventContextService.shared.cachedContext?.intentPrimary?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedGoal = (intentPrimary?.isEmpty == false)
            ? intentPrimary!
            : "Meet interesting people"

        // Pull from existing intelligence pipeline first.
        let sections = PeopleIntelligenceController.shared.sections
        let rankedPeople = (sections.hereNow + sections.followUp + sections.notHere)
            .sorted { $0.priorityScore > $1.priorityScore }

        var chosenPeople: [PriorityPerson] = []
        var chosenIds = Set<UUID>()
        for person in rankedPeople {
            guard chosenPeople.count < 3 else { break }
            guard person.id != myId else { continue }
            guard !chosenIds.contains(person.id) else { continue }

            let rel = relationships.first(where: { $0.profileId == person.id })
            let reason = buildReason(
                person: person,
                relationship: rel,
                eventName: eventName,
                goal: resolvedGoal
            )
            chosenPeople.append(
                PriorityPerson(
                    id: person.id,
                    name: person.name,
                    avatarUrl: person.avatarUrl,
                    reason: reason
                )
            )
            chosenIds.insert(person.id)
        }

        // Lightweight natural-language reasoning based on existing EL-style factors.
        let whyFactors = [
            "prior interaction",
            "shared interests",
            "repeated overlap"
        ]
        let whyLine = "Suggestions are based on \(whyFactors.joined(separator: ", "))."

        // Reuse existing prompt logic style: short, practical starters.
        var starters: [String] = []
        if let firstPerson = chosenPeople.first {
            let firstName = firstPerson.name.components(separatedBy: " ").first ?? firstPerson.name
            starters.append("Ask \(firstName) what they’re most focused on today.")
        }
        if let sharedTopic = myInterests.first {
            starters.append("Open with \(sharedTopic) — easy shared ground.")
        }
        starters.append("What brought you to \(eventName)?")
        starters = Array(starters.prefix(3))

        // Optional missed opportunity signal.
        let misses = relationships.filter {
            $0.profileId != myId
            && $0.totalOverlapSeconds >= 120
            && $0.connectionStatus == .none
        }
        let missedOpportunityLine: String?
        if misses.count >= 2 {
            missedOpportunityLine = "You’ve crossed paths with \(misses.count) people before but never connected."
        } else if let miss = misses.first {
            let name = miss.name.components(separatedBy: " ").first ?? miss.name
            missedOpportunityLine = "You and \(name) have crossed paths before but haven’t connected yet."
        } else {
            missedOpportunityLine = nil
        }

        return Brief(
            goalLine: "Today’s goal: \(resolvedGoal)",
            priorityPeople: chosenPeople,
            whyLine: whyLine,
            conversationStarters: starters,
            missedOpportunityLine: missedOpportunityLine
        )
    }

    private static func buildReason(
        person: PersonIntelligence,
        relationship: RelationshipMemory?,
        eventName: String,
        goal: String
    ) -> String {
        if let relationship {
            let minutes = max(relationship.totalOverlapSeconds / 60, 0)
            let goalTokens = tokenize(goal)
            let shared = Set(relationship.sharedInterests.map { $0.lowercased() })
            let intentAligned = !goalTokens.isDisjoint(with: shared)

            if minutes >= 10 {
                return "strong prior interaction (\(minutes) min together)"
            }
            if intentAligned, let topic = relationship.sharedInterests.first {
                return "high intent alignment around \(topic)"
            }
            if relationship.encounterCount >= 3 {
                return "repeated overlap across recent events"
            }
            if relationship.eventContexts.contains(eventName) {
                return "you’ve both shown up at this event before"
            }
        }

        if let firstDeep = person.deepInsights.first(where: { $0.category == "Interaction" || $0.category == "Relationship" })?.text {
            return firstDeep.lowercased()
        }
        return "high potential for a meaningful conversation"
    }

    private static func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}
