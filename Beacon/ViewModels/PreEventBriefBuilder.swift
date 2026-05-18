import Foundation

/// Computes a lightweight pre-event brief from existing intelligence sources.
/// No new backend calls and no schema changes.
@MainActor
enum PreEventBriefBuilder {
    struct AttendeeCountSemantics {
        let totalJoinedIncludingSelf: Int
        let joinedOthers: Int
        let liveOthers: Int
        let recommendationEligible: Int
        let recentlyNearby: Int
        let previewLikelyCount: Int
    }
    private enum MomentumState: String {
        case empty
        case forming
        case active
        case recentlyActive
    }

    struct Brief {
        let isLive: Bool
        let attendeeCounts: AttendeeCountSemantics
        let goalLine: String
        let goalContextLine: String
        let joinedSummary: [String]
        let priorityPeople: [PriorityPerson]
        let conversationStarters: [String]
        let liveStatusLine: String
    }

    struct PriorityPerson: Identifiable {
        enum RecommendationConfidenceTier: String {
            case exploratory
            case promising
            case strongMatch
            case highAlignment

            var displayLabel: String {
                switch self {
                case .exploratory: return "Exploratory"
                case .promising: return "Promising"
                case .strongMatch: return "Strong match"
                case .highAlignment: return "High alignment"
                }
            }
        }

        let id: UUID
        let name: String
        let avatarUrl: String?
        let statusLabel: String?
        let reason: String
        let matchScore: Double?
        let confidence: Double?
        let isNearby: Bool?
        let confidenceTier: RecommendationConfidenceTier
    }

    /// Builds a brief for the current joined event state.
    /// - Parameter joinedCount: Pre-fetched attendee count bypassing EventAttendeesService's
    ///   presence gate. Nil falls back to attendees.count (zero for pre-check-in users).
    /// - Parameter preEventPeople: Pre-built people list from BriefHydrationController's
    ///   direct attendee fetch. Overrides buildPredictivePeople for pre-check-in users.
    static func build(
        eventId: UUID,
        eventName: String,
        joinedCount: Int? = nil,
        preEventPeople: [PriorityPerson]? = nil
    ) -> Brief {
        let relationships = RelationshipMemoryService.shared.relationships
        let myId = AuthService.shared.currentUser?.id
        let isCheckedIn = EventJoinService.shared.isCheckedIn
        let intentPrimary = EventContextService.shared.cachedContext?.intentPrimary?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedGoal = (intentPrimary?.isEmpty == false)
            ? intentPrimary!
            : "Choose your goal to tune recommendations at check-in"

        let chosenPeople: [PriorityPerson]
        if isCheckedIn {
            chosenPeople = buildLivePeople(myId: myId, relationships: relationships, goal: resolvedGoal)
        } else if let preEventPeople, !preEventPeople.isEmpty {
            chosenPeople = preEventPeople
        } else {
            chosenPeople = buildPredictivePeople(myId: myId, relationships: relationships, eventName: eventName, goal: resolvedGoal)
        }

        let starters = buildStarters(
            isCheckedIn: isCheckedIn,
            chosenPeople: chosenPeople,
            goal: resolvedGoal,
            relationships: relationships
        )

        let attendeeCounts = makeAttendeeCountSemantics(joinedCount: joinedCount, chosenPeople: chosenPeople)
        let joinedSummary = buildJoinedSummary(
            isCheckedIn: isCheckedIn,
            chosenPeople: chosenPeople,
            relationships: relationships,
            goal: resolvedGoal,
            counts: attendeeCounts
        )

        return Brief(
            isLive: isCheckedIn,
            attendeeCounts: attendeeCounts,
            goalLine: resolvedGoal,
            goalContextLine: buildGoalContextLine(goal: resolvedGoal, relationships: relationships),
            joinedSummary: joinedSummary,
            priorityPeople: chosenPeople,
            conversationStarters: starters,
            liveStatusLine: isCheckedIn
                ? "Live proximity recommendations are active now."
                : "Live proximity recommendations activate after check-in."
        )
    }
    
    private static func buildGoalContextLine(goal: String, relationships: [RelationshipMemory]) -> String {
        let goalTokens = tokenize(goal)
        let aligned = relationships.filter { relation in
            !goalTokens.isDisjoint(with: Set(relation.sharedInterests.map { $0.lowercased() }))
        }.count
        if aligned >= 3 { return "Several attendees aligned with your goal are already joining." }
        if aligned > 0 { return "People with similar goals are already joining." }
        return "This event is beginning to attract attendees aligned with your goal."
    }

    private static func buildJoinedSummary(
        isCheckedIn: Bool,
        chosenPeople: [PriorityPerson],
        relationships: [RelationshipMemory],
        goal: String,
        counts: AttendeeCountSemantics
    ) -> [String] {
        let resolvedJoinedCount = counts.joinedOthers
        let liveCount = counts.liveOthers
        let recentlyNearbyCount = counts.recentlyNearby
        let mode = SocialStateResolver.shared.state.mode
        let momentumState: MomentumState = {
            if liveCount > 0 { return .active }
            if recentlyNearbyCount > 0 { return .recentlyActive }
            if resolvedJoinedCount > 0 || !chosenPeople.isEmpty { return .forming }
            return .empty
        }()

        var summary: [String] = [arrivalToneHeadline(
            mode: mode,
            momentumState: momentumState,
            joinedCount: resolvedJoinedCount,
            liveCount: liveCount
        )]
        if let continuityLine = continuityLine(mode: mode, momentumState: momentumState, recentlyNearbyCount: recentlyNearbyCount) {
            summary.append(continuityLine)
        }
        let goalTokens = tokenize(goal)
        let overlapCount = relationships.filter { relation in
            !goalTokens.isDisjoint(with: Set(relation.sharedInterests.map { $0.lowercased() }))
        }.count
        if overlapCount > 0 {
            summary.append("\(overlapCount) attendees show intent overlap with your goal")
        }
        let returning = relationships.filter { $0.encounterCount >= 2 }.count
        if returning > 1 {
            summary.append("Several returning community members are attending")
        }
        if !isCheckedIn {
            let collaboration = relationships.filter { relation in
                relation.sharedInterests.contains { $0.lowercased().contains("cofounder") || $0.lowercased().contains("collab") }
            }.count
            if collaboration > 0 {
                summary.append("\(collaboration) attendees are also looking for collaborators")
            }
        }
        DebugLog.verbose("[MomentumFraming] mode=\(mode.rawValue) joined=\(resolvedJoinedCount) live=\(liveCount) recentlyNearby=\(recentlyNearbyCount) state=\(momentumState.rawValue)")
        DebugLog.verbose("[SocialMomentum] mode=\(mode.rawValue) state=\(momentumState.rawValue) liveCount=\(liveCount) recentlyNearby=\(recentlyNearbyCount)")
        DebugLog.verbose("[ArrivalTone] path=joinedSummary.primary mode=\(mode.rawValue) state=\(momentumState.rawValue) line=\"\(summary.first ?? "")\"")
        return Array(summary.prefix(3))
    }

    private static func makeAttendeeCountSemantics(
        joinedCount: Int?,
        chosenPeople: [PriorityPerson]
    ) -> AttendeeCountSemantics {
        let mode = SocialStateResolver.shared.state.mode
        let attendees = EventAttendeesService.shared.attendees
        let liveOthers = EventAttendeesService.shared.liveOtherCount
        let liveRecommendationEligible = EventAttendeesService.shared.recommendationEligibleCount
        let now = Date()
        let recentlyNearby = attendees.filter { !$0.isHereNow && now.timeIntervalSince($0.lastSeen) < 300 }.count
        let joinedOthersPreEvent = max(joinedCount ?? attendees.count, chosenPeople.count)

        let joinedOthers: Int
        let recommendationEligible: Int
        let previewLikelyCount: Int

        if mode == .liveNavigation {
            // Live navigation semantics must be sourced from active/live attendee signals.
            joinedOthers = liveOthers
            recommendationEligible = max(liveRecommendationEligible, liveOthers)
            previewLikelyCount = 0
            DebugLog.verbose("[LiveSemanticSource] mode=liveNavigation source=activeAttendees liveOthers=\(liveOthers) joinedOthers=\(joinedOthers)")
            DebugLog.verbose("[LiveRecommendationEligibility] liveRecommendations=\(liveRecommendationEligible) eligible=\(recommendationEligible)")
            if joinedOthersPreEvent != joinedOthers {
                DebugLog.verbose("[LiveSemanticCorrection] replaced hydrated fallback with live counts hydratedJoined=\(joinedOthersPreEvent) liveJoined=\(joinedOthers)")
            }
        } else {
            joinedOthers = joinedOthersPreEvent
            recommendationEligible = max(chosenPeople.count, liveOthers)
            previewLikelyCount = max(joinedOthers, recommendationEligible, recentlyNearby)
        }

        let joinedSource = mode == .liveNavigation
            ? "activeLiveAttendees"
            : (joinedCount != nil ? "briefHydration" : (chosenPeople.isEmpty ? "attendeesService" : "priorityPeople"))
        DebugLog.verbose("[CountSource] mode=\(mode.rawValue) joinedOthers=\(joinedOthers) source=\(joinedSource)")
        DebugLog.verbose("[CountSource] mode=\(mode.rawValue) liveOthers=\(liveOthers) source=activeLiveAttendees")
        DebugLog.verbose("[CountSource] mode=\(mode.rawValue) recommendationEligible=\(recommendationEligible) source=\(mode == .liveNavigation ? "liveRecommendationEligibility" : "priorityPeople")")
        DebugLog.verbose("[CountSource] mode=\(mode.rawValue) recentlyNearby=\(recentlyNearby) source=resolverRecentNearby")
        DebugLog.verbose("[CountSource] mode=\(mode.rawValue) previewLikelyCount=\(previewLikelyCount) source=\(mode == .liveNavigation ? "disabledInLiveNavigation" : "priorityPeople")")
        DebugLog.verbose("[CountSemantics] mode=\(mode.rawValue) totalJoinedIncludingSelf=\(joinedOthers + 1) joinedOthers=\(joinedOthers) liveOthers=\(liveOthers) recommendationEligible=\(recommendationEligible) recentlyNearby=\(recentlyNearby) previewLikelyCount=\(previewLikelyCount)")
        return AttendeeCountSemantics(
            totalJoinedIncludingSelf: joinedOthers + 1,
            joinedOthers: joinedOthers,
            liveOthers: liveOthers,
            recommendationEligible: recommendationEligible,
            recentlyNearby: recentlyNearby,
            previewLikelyCount: previewLikelyCount
        )
    }

    private static func isCheckedInMode(_ mode: SocialStateResolver.SocialMode) -> Bool {
        mode == .liveNavigation
    }

    private static func arrivalToneHeadline(
        mode: SocialStateResolver.SocialMode,
        momentumState: MomentumState,
        joinedCount: Int,
        liveCount: Int
    ) -> String {
        switch mode {
        case .preEventPreparation:
            switch momentumState {
            case .empty:
                return "People are still arriving"
            case .forming:
                return "\(joinedCount) people plan to attend"
            case .active:
                return "\(liveCount) people are active now"
            case .recentlyActive:
                return "\(joinedCount) people joined this event"
            }
        case .earlyArrival:
            switch momentumState {
            case .empty:
                return "You’re among the first to arrive"
            case .forming:
                return "\(joinedCount) people joined this event"
            case .active:
                return "\(liveCount) people are active now"
            case .recentlyActive:
                return "The room is starting to become active"
            }
        case .liveNavigation:
            switch momentumState {
            case .empty:
                return "People are still arriving"
            case .forming:
                return "\(joinedCount) people joined this event"
            case .active:
                return "\(liveCount) people are active now"
            case .recentlyActive:
                return "People were nearby recently"
            }
        }
    }

    private static func continuityLine(
        mode: SocialStateResolver.SocialMode,
        momentumState: MomentumState,
        recentlyNearbyCount: Int
    ) -> String? {
        guard recentlyNearbyCount > 0 else {
            if mode == .earlyArrival, momentumState == .forming {
                return "Others are expected soon"
            }
            return nil
        }
        switch mode {
        case .preEventPreparation:
            return "People were nearby recently"
        case .earlyArrival:
            return "Nearify will surface live people as they arrive"
        case .liveNavigation:
            return "Nearify will surface live people as they arrive"
        }
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
                    reason: reason,
                    matchScore: nil,
                    confidence: nil,
                    isNearby: nil,
                    confidenceTier: .exploratory
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

        let rankedSeed = attendees.map { attendee in
            let rel = relationships.first(where: { $0.profileId == attendee.id })
            let proximity = resolver.resolveProximity(for: attendee)
            let score = liveMatchScore(relationship: rel, proximity: proximity, isHereNow: attendee.isHereNow, goal: goal)
            let diversityPenalty = diversityPenalty(for: rel)
            let noveltyBoost = noveltyBoost(for: rel)
            let diversifiedScore = score - diversityPenalty + noveltyBoost
            if diversityPenalty > 0 {
                DebugLog.verbose("[RecommendationDiversity] target=\(attendee.id.uuidString.prefix(8)) deprioritized repeated cluster exposure penalty=\(String(format: "%.1f", diversityPenalty))")
            }
            return (attendee, rel, proximity, score, diversifiedScore)
        }
        .sorted { (lhs: (attendee: EventAttendee, rel: RelationshipMemory?, proximity: ProximityState, score: Double, diversifiedScore: Double), rhs: (attendee: EventAttendee, rel: RelationshipMemory?, proximity: ProximityState, score: Double, diversifiedScore: Double)) in
            if lhs.diversifiedScore == rhs.diversifiedScore {
                return lhs.attendee.name < rhs.attendee.name
            }
            return lhs.diversifiedScore > rhs.diversifiedScore
        }

        return rankedSeed.prefix(ProfileSignalService.shared.recommendedPersonCount).map { attendee, rel, proximity, liveScore, diversifiedScore in
            let nearby = proximity == .veryClose || proximity == .nearby
            let confidence = max(0.0, min(1.0, liveScore / 140.0))
            let tier = recommendationConfidenceTier(
                score: diversifiedScore,
                relationship: rel,
                isNearby: nearby,
                isHereNow: attendee.isHereNow
            )
            if let rel {
                DebugLog.verbose("[RelationshipContinuity] target=\(attendee.id.uuidString.prefix(8)) recurring event overlap count=\(rel.eventContexts.count)")
            }
            DebugLog.verbose("[RecommendationConfidence] target=\(attendee.id.uuidString.prefix(8)) tier=\(tier.rawValue)")
            return PriorityPerson(
                id: attendee.id,
                name: IdentityDisplayName.primaryName(name: attendee.name, email: attendee.publicEmail, debugSource: "PreEventBriefBuilder.swift"),
                avatarUrl: attendee.avatarUrl,
                statusLabel: statusLabel(isHereNow: attendee.isHereNow, proximity: proximity),
                reason: buildLiveReason(
                    relationship: rel,
                    goal: goal,
                    isNearby: nearby,
                    isHereNow: attendee.isHereNow
                ),
                matchScore: liveScore,
                confidence: confidence,
                isNearby: nearby,
                confidenceTier: tier
            )
        }
    }

    private static func diversityPenalty(for relationship: RelationshipMemory?) -> Double {
        guard let relationship else { return 0.0 }
        var penalty = 0.0
        if relationship.encounterCount >= 6 { penalty += 10.0 }
        if relationship.sharedInterests.count <= 1 { penalty += 6.0 }
        return penalty
    }

    private static func noveltyBoost(for relationship: RelationshipMemory?) -> Double {
        guard let relationship else { return 5.0 }
        var boost = 0.0
        if relationship.encounterCount <= 2 { boost += 6.0 }
        if relationship.sharedInterests.count >= 2 { boost += 4.0 }
        if relationship.eventContexts.count >= 2 { boost += 4.0 }
        return boost
    }

    private static func recommendationConfidenceTier(
        score: Double,
        relationship: RelationshipMemory?,
        isNearby: Bool,
        isHereNow: Bool
    ) -> PriorityPerson.RecommendationConfidenceTier {
        var quality = score
        if let relationship {
            quality += min(Double(relationship.encounterCount) * 2.0, 10.0)
            quality += min(Double(relationship.eventContexts.count) * 3.0, 12.0)
            quality += relationship.hasConversation ? 10.0 : 0.0
        }
        if isNearby { quality += 12.0 }
        if isHereNow { quality += 8.0 }

        switch quality {
        case 145...: return .highAlignment
        case 125...: return .strongMatch
        case 100...: return .promising
        default: return .exploratory
        }
    }

    private static func liveMatchScore(
        relationship: RelationshipMemory?,
        proximity: ProximityState,
        isHereNow: Bool,
        goal: String
    ) -> Double {
        var score: Double = isHereNow ? 100.0 : 70.0
        switch proximity {
        case .veryClose: score += 20.0
        case .nearby: score += 15.0
        case .detected: score += 8.0
        case .lost: score += 0.0
        }

        if let relationship {
            score += Double(relationship.totalOverlapSeconds) / 120.0
            score += Double(relationship.encounterCount * 2)
            if !relationship.sharedInterests.isEmpty {
                score += 12.0
            }

            let goalTokens = tokenize(goal)
            let shared = Set(relationship.sharedInterests.map { $0.lowercased() })
            if !goalTokens.isDisjoint(with: shared) {
                score += 8.0
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
        if !person.topTraits.isEmpty, let why = TraitReasoning.whyThisMattersLine(traits: person.topTraits) {
            return "\(person.topTraits.joined(separator: " · ")) — \(why)"
        }

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
        return "Likely in the same conversation spaces today"
    }

    private static func buildLiveReason(
        relationship: RelationshipMemory?,
        goal: String,
        isNearby: Bool,
        isHereNow: Bool
    ) -> String {
        // Try cross-event enrichment from ProfileSignalService first.
        if let enriched = ProfileSignalService.shared.alignmentContext(for: relationship) {
            return enriched
        }
        if let relationship {
            // Mutual value framing: what they bring given the user's focus.
            if let mutual = ProfileSignalService.shared.mutualValueReason(for: relationship) {
                DebugLog.verbose("[RecommendationReasoning] target=\(relationship.profileId.uuidString.prefix(8)) reason=\"mutual value framing\"")
                return mutual
            }
            let traits = TraitReasoning.topTraits(for: relationship, isHereNow: isHereNow)
            if !traits.isEmpty, let why = TraitReasoning.whyThisMattersLine(traits: traits) {
                DebugLog.verbose("[RecommendationReasoning] target=\(relationship.profileId.uuidString.prefix(8)) reason=\"trait + momentum synthesis\"")
                return "\(traits.joined(separator: " · ")) — \(why)"
            }
        }

        guard let relationship else {
            if isNearby {
                return "They're nearby right now — a natural moment to walk over."
            }
            return isHereNow
                ? "Active at this event right now — a good moment to introduce yourself."
                : "Was active here recently and may still be around."
        }

        let minutes = max(relationship.totalOverlapSeconds / 60, 0)
        if minutes >= 15 {
            DebugLog.verbose("[RecommendationReasoning] target=\(relationship.profileId.uuidString.prefix(8)) reason=\"relationship memory overlap\"")
            return "You’ve already spent \(minutes) minutes near each other — strong interaction signal."
        }

        if let topic = relationship.sharedInterests.first {
            let goalTokens = tokenize(goal)
            let shared = Set(relationship.sharedInterests.map { $0.lowercased() })
            if !goalTokens.isDisjoint(with: shared) {
                if isNearby {
                    DebugLog.verbose("[RecommendationReasoning] target=\(relationship.profileId.uuidString.prefix(8)) reason=\"goal intent alignment + live proximity\"")
                    return "High overlap with your goal in \(topic), and they're nearby now."
                }
                return "High overlap with your goal in \(topic), with live event activity now."
            }
            DebugLog.verbose("[RecommendationReasoning] target=\(relationship.profileId.uuidString.prefix(8)) reason=\"shared interest + live confidence\"")
            return "Clear shared interest in \(topic), with a live event signal."
        }

        if relationship.encounterCount >= 2 {
            return "You’ve crossed paths \(relationship.encounterCount)x at recent events — strong repeat signal."
        }

        if isNearby {
            return "Strong live signal: they're nearby now and aligned with your event goal."
        }
        return "This is your strongest live match right now."
    }

    private static func buildStarters(
        isCheckedIn: Bool,
        chosenPeople: [PriorityPerson],
        goal: String,
        relationships: [RelationshipMemory]
    ) -> [String] {
        let signals = ProfileSignalService.shared
        if isCheckedIn {
            var starters: [String] = []
            if let first = chosenPeople.first {
                let rel = relationships.first { $0.profileId == first.id }
                if let personStarter = signals.conversationStarter(for: rel) {
                    starters.append(personStarter)
                } else {
                    switch signals.energyTone {
                    case .soft:
                        starters.append("When you're ready, \(first.name) is a natural first conversation.")
                    case .proactive:
                        starters.append("Start with \(first.name) — \(first.statusLabel ?? "here now") and strongly aligned.")
                    case .neutral:
                        starters.append("Start with \(first.name) while they're \(first.statusLabel ?? "here now").")
                    }
                }
            }

            if let goalTopic = strongestGoalTopic(goal: goal, relationships: relationships) {
                starters.append("Use \(goalTopic) as your opener to stay aligned with your goal.")
            } else {
                starters.append("Lead with what you're looking for at this event and invite collaboration.")
            }

            return starters
        }

        // Pre-check-in: try goal-aware starter from ProfileSignalService.
        if let goalStarter = signals.conversationStarter(for: nil) {
            return [goalStarter, "Ask what they're working on right now"]
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
