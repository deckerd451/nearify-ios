import Foundation

@MainActor
enum PeopleRelationshipAdapter {
    static func merge(basePeople: [PersonIntelligence], claimedGuestMemories: [ClaimedGuestInteractionMemory], savedProfileIds: Set<UUID>) -> [PersonIntelligence] {
        #if DEBUG
        print("[PeopleRelationship] Loaded claimed guest interactions: \(claimedGuestMemories.count)")
        #endif

        var merged: [UUID: PersonIntelligence] = [:]
        for person in basePeople {
            merged[person.id] = promote(person: person, with: person, reason: "base")
        }

        for memory in claimedGuestMemories {
            let guest = PeopleIntelligenceBuilder.buildFromClaimedGuestMemory(memory)
            merged[memory.profileId] = promote(person: merged[memory.profileId], with: guest, reason: "claimed")
        }

        for id in savedProfileIds {
            if var existing = merged[id], existing.relationshipState != PeopleRelationshipState.savedContact {
                let before = existing.relationshipState
                existing = PersonIntelligence(
                    id: existing.id, name: existing.name, displayName: existing.displayName, avatarUrl: existing.avatarUrl,
                    presence: existing.presence, presenceSource: existing.presenceSource,
                    connectionStatus: existing.connectionStatus, isTargetIntent: existing.isTargetIntent,
                    distilledInsight: "Saved to Contacts", topTraits: existing.topTraits, whyThisMatters: existing.whyThisMatters,
                    primaryAction: existing.primaryAction, secondaryAction: existing.secondaryAction,
                    deepInsights: existing.deepInsights,
                    priorityScore: existing.priorityScore + 12,
                    liveEventName: existing.liveEventName, lastEventName: existing.lastEventName,
                    relationshipState: PeopleRelationshipState.savedContact
                )
                merged[id] = existing
                #if DEBUG
                print("[PeopleRelationship] Promoted \(id.uuidString) to \(existing.relationshipState)")
                print("[PeopleRelationship] Previous state: \(before)")
                #endif
            }
        }

        #if DEBUG
        print("[PeopleRelationship] Merged people count: \(merged.count)")
        #endif
        var mergedPeople = Array(merged.values)

        if let currentProfileId = AuthService.shared.currentUser?.id {
            let before = mergedPeople.count
            mergedPeople.removeAll { $0.id == currentProfileId }
            if mergedPeople.count != before {
                #if DEBUG
                print("[PeopleRelationship] Filtered self profile from relationship results")
                #endif
            }
        }

        return mergedPeople
    }

    private static func promote(person current: PersonIntelligence?, with candidate: PersonIntelligence, reason: String) -> PersonIntelligence {
        guard let current else { return candidate }
        let mergedAvatar = preferredAvatar(primary: current.avatarUrl, secondary: candidate.avatarUrl)
        let keptExistingAvatar = mergedAvatar == current.avatarUrl
        let overwritten = mergedAvatar == candidate.avatarUrl && current.avatarUrl != mergedAvatar
        if mergedAvatar != current.avatarUrl || mergedAvatar != candidate.avatarUrl {
            print("[PeopleAvatarMerge] profile=\(candidate.id.uuidString.prefix(8)) keptAvatar=\(keptExistingAvatar) overwritten=\(overwritten)")
        }

        let currentWithAvatar = PersonIntelligence(
            id: current.id, name: current.name, displayName: current.displayName, avatarUrl: mergedAvatar,
            presence: current.presence, presenceSource: current.presenceSource,
            connectionStatus: current.connectionStatus, isTargetIntent: current.isTargetIntent,
            distilledInsight: current.distilledInsight, topTraits: current.topTraits, whyThisMatters: current.whyThisMatters,
            primaryAction: current.primaryAction, secondaryAction: current.secondaryAction,
            deepInsights: current.deepInsights, priorityScore: current.priorityScore,
            liveEventName: current.liveEventName, lastEventName: current.lastEventName,
            relationshipState: current.relationshipState
        )

        let candidateWithAvatar = PersonIntelligence(
            id: candidate.id, name: candidate.name, displayName: candidate.displayName, avatarUrl: mergedAvatar,
            presence: candidate.presence, presenceSource: candidate.presenceSource,
            connectionStatus: candidate.connectionStatus, isTargetIntent: candidate.isTargetIntent,
            distilledInsight: candidate.distilledInsight, topTraits: candidate.topTraits, whyThisMatters: candidate.whyThisMatters,
            primaryAction: candidate.primaryAction, secondaryAction: candidate.secondaryAction,
            deepInsights: candidate.deepInsights, priorityScore: candidate.priorityScore,
            liveEventName: candidate.liveEventName, lastEventName: candidate.lastEventName,
            relationshipState: candidate.relationshipState
        )

        if candidateWithAvatar.relationshipState > currentWithAvatar.relationshipState {
            #if DEBUG
            print("[PeopleRelationship] Promoted \(candidate.id.uuidString) to \(candidate.relationshipState)")
            #endif
            return candidateWithAvatar
        }
        return currentWithAvatar
    }

    private static func preferredAvatar(primary: String?, secondary: String?) -> String? {
        let first = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first, !first.isEmpty { return first }
        let second = secondary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let second, !second.isEmpty { return second }
        return nil
    }
}
