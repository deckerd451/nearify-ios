import Foundation

enum TraitReasoning {

    // MARK: - Relationship-based traits

    static func topTraits(for relationship: RelationshipMemory, isHereNow: Bool) -> [String] {
        var traits: [String] = []

        // Domain label from shared interests — most specific signal, shown first.
        if !relationship.sharedInterests.isEmpty {
            traits.append(domainLabel(from: relationship.sharedInterests))
        }

        // Longitudinal signals — factual and socially grounding.
        if relationship.encounterCount >= 3 || relationship.totalOverlapSeconds >= 1_200 {
            traits.append("Recurring Presence")
        }

        if relationship.hasConversation && relationship.connectionStatus == .accepted {
            traits.append("Follows Through")
        }

        if isHereNow && relationship.encounterCount >= 1 && traits.count < 2 {
            traits.append("Active Here Now")
        }

        return Array(traits.prefix(2))
    }

    // MARK: - Attendee-based traits (no relationship history yet)

    static func topTraits(for attendee: EventAttendee) -> [String] {
        var traits: [String] = []

        let interests = attendee.interests ?? []
        let skills = attendee.skills ?? []
        let allSignals = interests + skills

        if !allSignals.isEmpty {
            traits.append(domainLabel(from: allSignals))
        }

        if !skills.isEmpty && traits.count < 2 {
            traits.append("Technical Background")
        }

        if traits.isEmpty {
            traits.append("Active Attendee")
        }

        return Array(traits.prefix(2))
    }

    // MARK: - Why This Matters

    static func whyThisMattersLine(traits: [String]) -> String? {
        guard !traits.isEmpty else { return nil }
        let set = Set(traits)

        // High-specificity domain combinations.
        if set.contains("Healthcare + AI") || (set.contains("Healthcare Focus") && set.contains("AI Focus")) {
            return "Deep crossover between AI and healthcare — a rare combination."
        }
        if set.contains("AI Focus") && set.contains("Technical Builder") {
            return "You can quickly find common ground and build on it."
        }
        if set.contains("Startup Focus") && set.contains("Technical Builder") {
            return "Technical founders often build strong momentum from conversations like this."
        }
        if set.contains("Design Focus") && set.contains("Technical Builder") {
            return "Product + engineering overlap tends to create fast alignment."
        }
        if set.contains("Investment Focus") {
            return "Worth a brief conversation — they're active in funding and growth discussions."
        }
        if set.contains("Web3 Focus") {
            return "Active in the same technical community — easy shared context."
        }
        if set.contains("Climate Focus") {
            return "Shared interest in an area that rewards genuine collaboration."
        }

        // Single-domain explanations.
        if set.contains("Follows Through") {
            return "They're likely to continue the conversation after the event."
        }
        if set.contains("Recurring Presence") {
            return "The familiarity makes this conversation easier to start."
        }
        if let first = traits.first, first.hasSuffix("Focus") || first.hasSuffix("Builder") {
            return "Strong domain alignment — this conversation should feel natural."
        }
        if set.contains("Active Here Now") {
            return "Good timing — they're actively engaged at this event right now."
        }
        if set.contains("Data + Research") {
            return "Research-oriented — they tend to go deeper in conversations."
        }
        if set.contains("Growth Focus") {
            return "Growth-focused people often move quickly once there's a fit."
        }

        return "This looks like a relevant conversation right now."
    }

    // MARK: - Domain Label

    /// Infers a concise domain label from a list of interest/skill strings.
    /// Keyword matching only — no inference, no external calls.
    static func domainLabel(from signals: [String]) -> String {
        let joined = signals.map { $0.lowercased() }.joined(separator: " ")

        let hasAI = joined.contains("ai") || joined.contains("machine learning")
            || joined.contains(" ml ") || joined.contains("llm") || joined.contains("gpt")
            || joined.contains("deep learning") || joined.contains("neural")
        let hasHealth = joined.contains("health") || joined.contains("medical")
            || joined.contains("clinic") || joined.contains("pharma") || joined.contains("biotech")
            || joined.contains("medtech") || joined.contains("hospital")

        if hasAI && hasHealth { return "Healthcare + AI" }
        if hasAI { return "AI Focus" }
        if hasHealth { return "Healthcare Focus" }

        if joined.contains("invest") || joined.contains("venture") || joined.contains(" vc ")
            || joined.contains("capital") || joined.contains("fund") {
            return "Investment Focus"
        }
        if joined.contains("crypto") || joined.contains("web3") || joined.contains("blockchain")
            || joined.contains("defi") || joined.contains("nft") {
            return "Web3 Focus"
        }
        if joined.contains("climate") || joined.contains("sustain") || joined.contains("clean energy")
            || joined.contains("greentech") || joined.contains("cleantech") {
            return "Climate Focus"
        }
        if joined.contains("fintech") || joined.contains("finance") || joined.contains("banking")
            || joined.contains("payment") || joined.contains("neobank") {
            return "Fintech Focus"
        }

        let hasDesign = joined.contains("design") || joined.contains("ux") || joined.contains(" ui ")
            || joined.contains("product design") || joined.contains("user research")
        let hasTech = joined.contains("engineer") || joined.contains("developer")
            || joined.contains("software") || joined.contains("backend") || joined.contains("frontend")
            || joined.contains("fullstack") || joined.contains("technical")

        if hasDesign && hasTech { return "Technical Builder" }
        if hasDesign { return "Design Focus" }
        if hasTech { return "Technical Builder" }

        if joined.contains("founder") || joined.contains("cofounder") || joined.contains("startup")
            || joined.contains("co-founder") {
            return "Startup Focus"
        }
        if joined.contains("data") || joined.contains("analyt") || joined.contains("research")
            || joined.contains("scientist") {
            return "Data + Research"
        }
        if joined.contains("market") || joined.contains("growth") || joined.contains("sales")
            || joined.contains("brand") || joined.contains("gtm") {
            return "Growth Focus"
        }
        if joined.contains("content") || joined.contains("media") || joined.contains("journalism")
            || joined.contains("storytell") {
            return "Media + Content"
        }
        if joined.contains("community") || joined.contains("operations") || joined.contains("program") {
            return "Community Builder"
        }

        // Fallback: capitalize first signal rather than a generic label.
        let first = signals.first ?? ""
        let capitalized = first.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return capitalized.isEmpty ? "Shared Focus" : capitalized
    }
}
