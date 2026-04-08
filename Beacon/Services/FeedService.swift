import Foundation
import Combine
import Supabase

/// Fetches and manages the Social Memory Feed.
/// Feed items are system-generated from connections, encounters, messages.
/// All profile IDs reference profiles.id (community identity).
@MainActor
final class FeedService: ObservableObject {

    static let shared = FeedService()

    @Published private(set) var feedItems: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    private let supabase = AppEnvironment.shared.supabaseClient

    // MARK: - Refresh Coalescing

    private var isRefreshing = false
    private var pendingRefreshReason: String?
    private var refreshTask: Task<Void, Never>?

    private init() {}

    // MARK: - Centralized Refresh Entry Point

    /// Single safe entry point for all feed refresh requests.
    /// Coalesces overlapping requests — if a refresh is already running,
    /// marks one pending refresh instead of spawning parallel work.
    func requestRefresh(reason: String) {
        if isRefreshing {
            pendingRefreshReason = reason
            #if DEBUG
            print("[Feed] 🔄 Refresh already running — coalescing (\(reason))")
            #endif
            return
        }

        #if DEBUG
        print("[Feed] 🔄 Refresh requested: \(reason)")
        #endif

        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task {
            await performFullRefresh()

            // If a pending request came in while we were refreshing, do one more
            if let pending = pendingRefreshReason {
                pendingRefreshReason = nil
                #if DEBUG
                print("[Feed] 🔄 Running coalesced refresh: \(pending)")
                #endif
                await performFullRefresh()
            }

            isRefreshing = false
            #if DEBUG
            print("[Feed] ✅ Refresh complete")
            #endif
        }
    }

    /// Internal: runs generation + fetch in sequence.
    private func performFullRefresh() async {
        guard let myId = AuthService.shared.currentUser?.id else {
            print("[Feed] ⚠️ No current user, skipping refresh")
            return
        }

        isLoading = true
        defer { isLoading = false }

        await generateConnectionFeedItems(myId: myId)
        await generateEncounterFeedItems(myId: myId)
        await generateMessageFeedItems(myId: myId)
        await fetchFeedItems(myId: myId)
    }

    /// Legacy: direct refresh of feed items only (no generation).
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            guard let myId = AuthService.shared.currentUser?.id else { return }
            isLoading = true
            defer { isLoading = false }
            await fetchFeedItems(myId: myId)
        }
    }

    // MARK: - Fetch Feed Items

    private func fetchFeedItems(myId: UUID) async {
        do {
            let items: [FeedItem] = try await supabase
                .from("feed_items")
                .select("*")
                .eq("viewer_profile_id", value: myId.uuidString)
                .order("priority_score", ascending: false)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            feedItems = items
            lastRefresh = Date()

            #if DEBUG
            print("[Feed] ✅ Loaded \(items.count) feed items")
            #endif
        } catch {
            print("[Feed] ❌ Failed to load feed: \(error)")
        }
    }

    // MARK: - Generate Connection Feed Items

    private func generateConnectionFeedItems(myId: UUID) async {
        do {
            let connections = try await ConnectionService.shared.fetchConnections()

            for conn in connections {
                let other = conn.otherUser(for: myId)
                let score = FeedPriorityScorer.scoreConnection(connectionCreatedAt: conn.createdAt)

                let metadata = FeedItemMetadata(
                    eventName: nil,
                    sharedInterests: nil,
                    actorName: other.name,
                    actorAvatarUrl: nil
                )

                let payload = FeedItemInsertPayload(
                    viewerProfileId: myId,
                    type: FeedItemType.connection.rawValue,
                    actorProfileId: other.id,
                    targetProfileId: nil,
                    eventId: conn.eventId,
                    priorityScore: score,
                    metadata: metadata,
                    createdAt: conn.createdAt
                )

                try await supabase
                    .from("feed_items")
                    .upsert(payload, onConflict: "viewer_profile_id,type,actor_profile_id,event_id")
                    .execute()
            }

            #if DEBUG
            print("[Feed] ✅ Generated connection feed items for \(connections.count) connections")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate connection feed items: \(error)")
        }
    }

    // MARK: - Generate Encounter Feed Items (batched profile lookup)

    private func generateEncounterFeedItems(myId: UUID) async {
        do {
            let encounters: [Encounter] = try await supabase
                .from("encounters")
                .select("*")
                .or("profile_a.eq.\(myId.uuidString),profile_b.eq.\(myId.uuidString)")
                .order("last_seen_at", ascending: false)
                .limit(20)
                .execute()
                .value

            // Deduplicate: keep strongest per (otherProfileId, eventId)
            var bestEncounters: [String: Encounter] = [:]
            for encounter in encounters {
                let otherId = encounter.otherProfile(for: myId)
                let key = "\(otherId)_\(encounter.eventId?.uuidString ?? "nil")"
                if let existing = bestEncounters[key] {
                    if (encounter.overlapSeconds ?? 0) > (existing.overlapSeconds ?? 0) {
                        bestEncounters[key] = encounter
                    }
                } else {
                    bestEncounters[key] = encounter
                }
            }

            #if DEBUG
            print("[Feed] 📊 Deduped to \(bestEncounters.count) unique encounters from \(encounters.count) total")
            #endif

            // Batch profile lookup for all encounter partners
            let otherIds = bestEncounters.values.map { $0.otherProfile(for: myId) }
            let profileMap = await ProfileService.shared.fetchProfilesByIds(otherIds)

            for encounter in bestEncounters.values {
                let otherId = encounter.otherProfile(for: myId)
                let actorName = profileMap[otherId]?.name
                let sourceTimestamp = encounter.lastSeenAt ?? encounter.firstSeenAt

                let score = FeedPriorityScorer.scoreEncounter(
                    sourceTimestamp: sourceTimestamp,
                    overlapSeconds: encounter.overlapSeconds
                )

                let metadata = FeedItemMetadata(
                    overlapSeconds: encounter.overlapSeconds,
                    actorName: actorName
                )

                let payload = FeedItemInsertPayload(
                    viewerProfileId: myId,
                    type: FeedItemType.encounter.rawValue,
                    actorProfileId: otherId,
                    targetProfileId: nil,
                    eventId: encounter.eventId,
                    priorityScore: score,
                    metadata: metadata,
                    createdAt: sourceTimestamp
                )

                try? await supabase
                    .from("feed_items")
                    .upsert(payload, onConflict: "viewer_profile_id,type,actor_profile_id,event_id")
                    .execute()
            }

            #if DEBUG
            print("[Feed] ✅ Encounter feed generation complete")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate encounter feed items: \(error)")
        }
    }

    // MARK: - Generate Message Feed Items (batched profile lookup)

    private func generateMessageFeedItems(myId: UUID) async {
        do {
            let conversations: [Conversation] = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .execute()
                .value

            guard !conversations.isEmpty else { return }

            // Batch profile lookup for all conversation partners
            let otherIds = conversations.map { $0.otherParticipant(for: myId) }
            let profileMap = await ProfileService.shared.fetchProfilesByIds(otherIds)

            for convo in conversations {
                let messages: [Message] = try await supabase
                    .from("messages")
                    .select("*")
                    .eq("conversation_id", value: convo.id.uuidString)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value

                guard let latestMessage = messages.first else { continue }

                let otherId = convo.otherParticipant(for: myId)
                let actorName = profileMap[otherId]?.name

                let score = FeedPriorityScorer.scoreMessage(sourceTimestamp: latestMessage.createdAt)

                let metadata = FeedItemMetadata(
                    messagePreview: String(latestMessage.content.prefix(80)),
                    conversationId: convo.id.uuidString,
                    actorName: actorName
                )

                // Delete-then-insert for NULL event_id dedup
                try await supabase
                    .from("feed_items")
                    .delete()
                    .eq("viewer_profile_id", value: myId.uuidString)
                    .eq("type", value: FeedItemType.message.rawValue)
                    .eq("actor_profile_id", value: otherId.uuidString)
                    .execute()

                let payload = FeedItemInsertPayload(
                    viewerProfileId: myId,
                    type: FeedItemType.message.rawValue,
                    actorProfileId: otherId,
                    targetProfileId: nil,
                    eventId: nil,
                    priorityScore: score,
                    metadata: metadata,
                    createdAt: latestMessage.createdAt
                )

                try await supabase
                    .from("feed_items")
                    .insert(payload)
                    .execute()
            }

            #if DEBUG
            print("[Feed] ✅ Message feed generation complete (\(conversations.count) conversations)")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate message feed items: \(error)")
        }
    }

    // MARK: - Public Generation Methods (for backward compat)

    func generateConnectionFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        await generateConnectionFeedItems(myId: myId)
    }

    func generateEncounterFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        await generateEncounterFeedItems(myId: myId)
    }

    func generateMessageFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        await generateMessageFeedItems(myId: myId)
    }

    // MARK: - Filter

    func filteredItems(by type: FeedItemType?) -> [FeedItem] {
        guard let type = type else { return feedItems }
        return feedItems.filter { $0.feedType == type }
    }
}

// MARK: - Insert Payload

private struct FeedItemInsertPayload: Encodable {
    let viewerProfileId: UUID
    let type: String
    let actorProfileId: UUID?
    let targetProfileId: UUID?
    let eventId: UUID?
    let priorityScore: Double
    let metadata: FeedItemMetadata?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case viewerProfileId  = "viewer_profile_id"
        case type
        case actorProfileId   = "actor_profile_id"
        case targetProfileId  = "target_profile_id"
        case eventId          = "event_id"
        case priorityScore    = "priority_score"
        case metadata
        case createdAt        = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(viewerProfileId, forKey: .viewerProfileId)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(actorProfileId, forKey: .actorProfileId)
        try container.encodeIfPresent(targetProfileId, forKey: .targetProfileId)
        try container.encodeIfPresent(eventId, forKey: .eventId)
        try container.encode(priorityScore, forKey: .priorityScore)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        if let createdAt = createdAt {
            try container.encode(createdAt, forKey: .createdAt)
        }
    }
}
