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
                    id: existing.id, name: existing.name, avatarUrl: existing.avatarUrl,
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
        if candidate.relationshipState > current.relationshipState {
            #if DEBUG
            print("[PeopleRelationship] Promoted \(candidate.id.uuidString) to \(candidate.relationshipState)")
            #endif
            return candidate
        }
        return current
    }
}
