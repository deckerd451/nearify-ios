import Foundation

enum TraitReasoning {

    static func topTraits(for relationship: RelationshipMemory, isHereNow: Bool) -> [String] {
        var traits: [String] = []

        if relationship.encounterCount >= 3 || relationship.totalOverlapSeconds >= 1_200 {
            traits.append("Community Builder")
        }

        if relationship.sharedInterests.count >= 2 {
            traits.append("Technical Connector")
        }

        if relationship.hasConversation && relationship.connectionStatus == .accepted {
            traits.append("Follows Through")
        }

        if isHereNow && relationship.encounterCount >= 1 {
            traits.append("Event Collaborator")
        }

        return Array(traits.prefix(2))
    }

    static func topTraits(for attendee: EventAttendee) -> [String] {
        var traits: [String] = []

        if let skills = attendee.skills, !skills.isEmpty {
            traits.append("Technical Connector")
        }
        if let interests = attendee.interests, interests.count >= 2 {
            traits.append("Community Builder")
        }

        if traits.isEmpty {
            traits.append("Active Attendee")
        }

        return Array(traits.prefix(2))
    }

    static func whyThisMattersLine(traits: [String]) -> String? {
        guard !traits.isEmpty else { return nil }

        let set = Set(traits)
        if set.contains("Community Builder") && set.contains("Technical Connector") {
            return "You both connect people and ideas at events."
        }
        if set.contains("Follows Through") {
            return "They're likely to continue the conversation after the event."
        }
        if set.contains("Technical Connector") {
            return "You can quickly align on topics and build momentum."
        }
        if set.contains("Community Builder") {
            return "They can open doors to useful people in the room."
        }
        return "This looks like a relevant conversation right now."
    }
}
