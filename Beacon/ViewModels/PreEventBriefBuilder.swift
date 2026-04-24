import Foundation

/// Computes a lightweight pre-event brief from existing intelligence sources.
/// No new backend calls and no schema changes.
@MainActor
enum PreEventBriefBuilder {

    struct Brief {
        let isLive: Bool
        let goalLine: String
        let priorityPeople: [PriorityPerson]
        let conversationStarters: [String]
    }

    struct PriorityPerson: Identifiable {
        let id: UUID
        let name: String
        let avatarUrl: String?
        let statusLabel: String?
        let reason: String
    }

    /// Builds a brief for the current joined event state.
    static func build(eventId: UUID, eventName: String) -> Brief {
        let relationships = RelationshipMemoryService.shared.relationships
        let myId = AuthService.shared.currentUser?.id
        let isCheckedIn = EventJoinService.shared.isCheckedIn
        let intentPrimary = EventContextService.shared.cachedContext?.intentPrimary?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedGoal = (intentPrimary?.isEmpty == false)
            ? intentPrimary!
            : "Meet interesting people"

        let chosenPeople = isCheckedIn
            ? buildLivePeople(myId: myId, relationships: relationships, goal: resolvedGoal)
            : buildPredictivePeople(myId: myId, relationships: relationships, eventName: eventName, goal: resolvedGoal)

        let starters = buildStarters(
            isCheckedIn: isCheckedIn,
            chosenPeople: chosenPeople,
            goal: resolvedGoal,
            relationships: relationships
        )

        return Brief(
            isLive: isCheckedIn,
            goalLine: resolvedGoal,
            priorityPeople: chosenPeople,
            conversationStarters: starters
        )
    }

    private static func buildPredictivePeople(
        myId: UUID?,
        relationships: [RelationshipMemory],
        eventName: String,
        goal: String
    ) -> [PriorityPerson] {
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
            let reason = buildPredictiveReason(
                person: person,
                relationship: rel,
                eventName: eventName,
                goal: goal
            )
            chosenPeople.append(
                PriorityPerson(
                    id: person.id,
                    name: person.name,
                    avatarUrl: person.avatarUrl,
                    statusLabel: nil,
                    reason: reason
                )
            )
            chosenIds.insert(person.id)
        }
        return chosenPeople
    }

    private static func buildLivePeople(
        myId: UUID?,
        relationships: [RelationshipMemory],
        goal: String
    ) -> [PriorityPerson] {
        let attendees = EventAttendeesService.shared.attendees
            .filter { $0.id != myId }
        let resolver = AttendeeStateResolver.shared

        let scored = attendees.map { attendee in
            let rel = relationships.first(where: { $0.profileId == attendee.id })
            let proximity = resolver.resolveProximity(for: attendee)
            let score = liveMatchScore(relationship: rel, proximity: proximity, isHereNow: attendee.isHereNow, goal: goal)
            return (attendee, rel, proximity, score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.attendee.name < rhs.attendee.name
            }
            return lhs.score > rhs.score
        }

        return scored.prefix(3).map { attendee, rel, proximity, _ in
            PriorityPerson(
                id: attendee.id,
                name: attendee.name,
                avatarUrl: attendee.avatarUrl,
                statusLabel: statusLabel(isHereNow: attendee.isHereNow, proximity: proximity),
                reason: buildLiveReason(relationship: rel, goal: goal)
            )
        }
    }

    private static func liveMatchScore(
        relationship: RelationshipMemory?,
        proximity: ProximityState,
        isHereNow: Bool,
        goal: String
    ) -> Double {
        var score = isHereNow ? 100 : 70
        switch proximity {
        case .veryClose: score += 20
        case .nearby: score += 15
        case .detected: score += 8
        case .lost: score += 0
        }

        if let relationship {
            score += Double(relationship.totalOverlapSeconds) / 120.0
            score += Double(relationship.encounterCount * 2)
            if !relationship.sharedInterests.isEmpty {
                score += 12
            }

            let goalTokens = tokenize(goal)
            let shared = Set(relationship.sharedInterests.map { $0.lowercased() })
            if !goalTokens.isDisjoint(with: shared) {
                score += 8
            }
        }

        return score
    }

    private static func statusLabel(isHereNow: Bool, proximity: ProximityState) -> String {
        if proximity == .veryClose || proximity == .nearby {
            return "nearby"
        }
        return isHereNow ? "here now" : "recently seen"
    }

    private static func buildPredictiveReason(
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
                return "You've spent time together (\(minutes) min)"
            }
            if intentAligned, let topic = relationship.sharedInterests.first {
                return "Overlapping interests in \(topic), aligned with your goal"
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

    private static func buildLiveReason(relationship: RelationshipMemory?, goal: String) -> String {
        guard let relationship else {
            return "Good chance for a useful conversation right now"
        }

        let minutes = max(relationship.totalOverlapSeconds / 60, 0)
        if minutes >= 15 {
            return "Strong overlap (\(minutes) min) — you've spent time together"
        }

        if let topic = relationship.sharedInterests.first {
            let goalTokens = tokenize(goal)
            let shared = Set(relationship.sharedInterests.map { $0.lowercased() })
            if !goalTokens.isDisjoint(with: shared) {
                return "Overlapping interests in \(topic), aligned with your goal"
            }
            return "Overlapping interests in \(topic)"
        }

        if relationship.encounterCount >= 2 {
            return "You've spent time together at recent events"
        }

        return "Potentially aligned with your goal"
    }

    private static func buildStarters(
        isCheckedIn: Bool,
        chosenPeople: [PriorityPerson],
        goal: String,
        relationships: [RelationshipMemory]
    ) -> [String] {
        if isCheckedIn {
            var starters: [String] = []
            if let first = chosenPeople.first {
                starters.append("Start with \(first.name) while they're \(first.statusLabel ?? "here now").")
            }

            if let goalTopic = strongestGoalTopic(goal: goal, relationships: relationships) {
                starters.append("Use \(goalTopic) as your opener to stay aligned with your goal.")
            } else {
                starters.append("Lead with what you're looking for at this event and invite collaboration.")
            }

            return starters
        }

        return [
            "Ask what brought them here",
            "Ask what they're working on right now"
        ]
    }

    private static func strongestGoalTopic(goal: String, relationships: [RelationshipMemory]) -> String? {
        let goalTokens = tokenize(goal)
        for relationship in relationships {
            for topic in relationship.sharedInterests {
                if goalTokens.contains(topic.lowercased()) {
                    return topic
                }
            }
        }
        return nil
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
