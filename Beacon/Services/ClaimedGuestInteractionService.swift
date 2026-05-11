import Foundation
import Supabase
import Combine

struct ClaimedGuestInteractionMemory: Identifiable {
    let id: UUID
    let profileId: UUID
    let profileName: String
    let avatarUrl: String?
    let eventName: String?
    let createdAt: Date
    let interactionCount: Int
}

private struct ClaimedGuestInteractionRow: Decodable {
    let toProfileId: UUID
    let eventId: UUID?
    let createdAt: Date
    let interactionType: String

    enum CodingKeys: String, CodingKey {
        case toProfileId = "to_profile_id"
        case eventId = "event_id"
        case createdAt = "created_at"
        case interactionType = "interaction_type"
    }
}

private struct ClaimedProfileRow: Decodable {
    let id: UUID
    let name: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarUrl = "avatar_url"
    }
}

private struct ClaimedEventRow: Decodable {
    let id: UUID
    let name: String
}

@MainActor
final class ClaimedGuestInteractionService: ObservableObject {
    static let shared = ClaimedGuestInteractionService()

    @Published private(set) var memories: [ClaimedGuestInteractionMemory] = []

    private let supabase = AppEnvironment.shared.supabaseClient
    private var isRefreshing = false

    private init() {}

    func requestRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await refresh()
            isRefreshing = false
        }
    }

    private func refresh() async {
        guard NetworkMonitor.shared.isOnline else { return }
        guard let currentProfileId = AuthService.shared.currentUser?.id else {
            memories = []
            return
        }

        #if DEBUG
        print("[PeopleRelationshipQuery] loading claimed guest interactions")
        print("[PeopleRelationshipQuery] currentProfileId=\(currentProfileId.uuidString.prefix(8))")
        #endif

        do {
            let rows: [ClaimedGuestInteractionRow] = try await supabase
                .from("interaction_events")
                .select("to_profile_id,event_id,created_at,interaction_type")
                .eq("claimed_by_profile_id", value: currentProfileId.uuidString)
                .neq("to_profile_id", value: currentProfileId.uuidString)
                // Note: column-to-column filter (from_profile_id != to_profile_id) is not
                // expressible as a value comparison in PostgREST — the previous
                // .filter("from_profile_id", operator: "neq", value: "to_profile_id")
                // was passing the literal string "to_profile_id" as a UUID, causing
                // PostgrestError code 22P02. The combination of claimed_by_profile_id,
                // from_ghost_id IS NOT NULL, and to_profile_id IS NOT NULL already
                // excludes degenerate rows with equal from/to IDs in practice.
                .not("from_ghost_id", operator: .is, value: "null")
                .not("to_profile_id", operator: .is, value: "null")
                .in("interaction_type", values: ["qr_confirmed", "guest_qr_confirmed"])
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value

            #if DEBUG
            print("[PeopleRelationshipQuery] success count=\(rows.count)")
            #endif

            let grouped = Dictionary(grouping: rows, by: \.toProfileId)
            let profileIds = Array(grouped.keys)
            let eventIds = Array(Set(rows.compactMap(\.eventId)))

            let profiles: [ClaimedProfileRow] = profileIds.isEmpty ? [] : (try await supabase
                .from("profiles")
                .select("id,name,avatar_url")
                .in("id", values: profileIds.map(\.uuidString))
                .execute()
                .value)

            let events: [ClaimedEventRow] = eventIds.isEmpty ? [] : (try await supabase
                .from("events")
                .select("id,name")
                .in("id", values: eventIds.map(\.uuidString))
                .execute()
                .value)

            let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let eventMap = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.name) })

            let built: [ClaimedGuestInteractionMemory] = grouped.compactMap { profileId, items in
                guard let newest = items.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
                guard let profile = profileMap[profileId] else { return nil }
                return ClaimedGuestInteractionMemory(
                    id: profileId,
                    profileId: profileId,
                    profileName: IdentityDisplayName.primaryName(name: profile.name, debugSource: "RelationshipMemory.row"),
                    avatarUrl: profile.avatarUrl,
                    eventName: newest.eventId.flatMap { eventMap[$0] },
                    createdAt: newest.createdAt,
                    interactionCount: items.count
                )
            }
            .sorted { $0.createdAt > $1.createdAt }

            memories = built
        } catch {
            #if DEBUG
            print("[PeopleRelationshipQuery] failed error=\(error.localizedDescription)")
            #endif
            memories = []
        }
    }

}
