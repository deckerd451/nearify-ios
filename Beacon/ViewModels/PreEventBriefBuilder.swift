import Foundation

/// Computes a lightweight pre-event brief from existing intelligence sources.
/// No new backend calls and no schema changes.
@MainActor
enum PreEventBriefBuilder {

    struct Brief {
        let goalLine: String
        let priorityPeople: [PriorityPerson]
        let conversationStarters: [String]
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

        let starters = [
            "Ask what brought them here",
            "Ask what they’re working on right now"
        ]

        return Brief(
            goalLine: resolvedGoal,
            priorityPeople: chosenPeople,
            conversationStarters: starters
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
                return "You’ve had repeated overlap (\(minutes) min)"
            }
            if intentAligned, let topic = relationship.sharedInterests.first {
                return "Shared interests in \(topic)"
            }
            if relationship.encounterCount >= 3 {
                return "You keep showing up at the same events"
            }
            if relationship.eventContexts.contains(eventName) {
                return "You’ve both shown up at this event before"
            }
        }

        if let firstDeep = person.deepInsights.first(where: { $0.category == "Interaction" || $0.category == "Relationship" })?.text {
            return firstDeep.lowercased()
        }
        return "Likely a strong conversation fit"
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
