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

    // MARK: - Event Name Cache
    // Resolves eventId → eventName for feed item metadata.
    // Populated once per refresh cycle, shared across all generators.
    private var eventNameCache: [UUID: String] = [:]

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

        // Skip network-dependent refresh when offline — existing cached items remain
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("[NearbyMode] skipping backend feature: feed refresh")
            #endif
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Compute zone-aware scoring multipliers once per refresh cycle.
        // FeedService is @MainActor, so reading UserPresenceStateResolver is safe here.
        // These plain Doubles are then passed into the nonisolated FeedPriorityScorer.
        let zoneBoost = UserPresenceStateResolver.feedZoneMultiplier
        let zoneSuppression = UserPresenceStateResolver.feedZoneSuppression

        await resolveEventNames(myId: myId)
        await generateConnectionFeedItems(myId: myId, zoneBoost: zoneBoost)
        await generateEncounterFeedItems(myId: myId, zoneBoost: zoneBoost)
        await generateMessageFeedItems(myId: myId, zoneBoost: zoneBoost)
        await fetchFeedItems(myId: myId)

        // Note: zoneSuppression is available for suggestion scoring when that
        // generation path is added. Currently suggestions are scored at read time.
        _ = zoneSuppression
    }

    // MARK: - Event Name Resolution

    /// Batch-resolves event names for all events the user has attended.
    /// Queries event_attendees → events to build a UUID→name cache.
    /// Called once per refresh cycle; individual generators read from the cache.
    private func resolveEventNames(myId: UUID) async {
        // Gather event IDs from event_attendees (past attendance)
        struct AttendanceRow: Decodable {
            let eventId: UUID
            enum CodingKeys: String, CodingKey {
                case eventId = "event_id"
            }
        }

        do {
            let rows: [AttendanceRow] = try await supabase
                .from("event_attendees")
                .select("event_id")
                .eq("profile_id", value: myId.uuidString)
                .execute()
                .value

            let eventIds = Array(Set(rows.map(\.eventId)))
            guard !eventIds.isEmpty else {
                eventNameCache = [:]
                return
            }

            // Batch fetch event names
            struct EventRow: Decodable {
                let id: UUID
                let name: String
            }

            let events: [EventRow] = try await supabase
                .from("events")
                .select("id,name")
                .in("id", values: eventIds.map(\.uuidString))
                .execute()
                .value

            var cache: [UUID: String] = [:]
            for event in events {
                cache[event.id] = event.name
            }

            // Also include the current/last event from EventJoinService
            if let lastCtx = EventJoinService.shared.reconnectContext,
               let lastId = UUID(uuidString: lastCtx.eventId) {
                cache[lastId] = lastCtx.eventName
            }
            if let currentId = EventJoinService.shared.currentEventID.flatMap({ UUID(uuidString: $0) }),
               let currentName = EventJoinService.shared.currentEventName {
                cache[currentId] = currentName
            }

            eventNameCache = cache

            #if DEBUG
            print("[Feed] 🗺️ Event name cache: \(cache.count) events resolved")
            for (id, name) in cache {
                print("[Feed]    \(id.uuidString.prefix(8))… → \(name)")
            }
            #endif
        } catch {
            print("[Feed] ⚠️ Event name resolution failed: \(error)")
            eventNameCache = [:]
        }
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

            // Evaluate feed items for notifications
            NotificationService.shared.evaluateFeedItems(items)

            #if DEBUG
            print("[Feed] ✅ Loaded \(items.count) feed items")
            #endif
        } catch {
            print("[Feed] ❌ Failed to load feed: \(error)")
        }
    }

    // MARK: - Generate Connection Feed Items

    private func generateConnectionFeedItems(myId: UUID, zoneBoost: Double = 1.0) async {
        do {
            let connections = try await ConnectionService.shared.fetchConnections()

            for conn in connections {
                let other = conn.otherUser(for: myId)
                let score = FeedPriorityScorer.scoreConnection(connectionCreatedAt: conn.createdAt, zoneMultiplier: zoneBoost)

                let resolvedEventName = conn.eventId.flatMap { eventNameCache[$0] }

                let metadata = FeedItemMetadata(
                    eventName: resolvedEventName,
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

    private func generateEncounterFeedItems(myId: UUID, zoneBoost: Double = 1.0) async {
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

            // Generate insights for encounter profiles
            let viewerProfile = AuthService.shared.currentUser
            let connectedIds = AttendeeStateResolver.shared.connectedIds
            let encounterSignals: [InteractionSignal] = bestEncounters.values.map { enc in
                let otherId = enc.otherProfile(for: myId)
                let profile = profileMap[otherId]
                let viewerInterests = Set(viewerProfile?.interests ?? [])
                let theirInterests = Set(profile?.interests ?? [])
                return InteractionSignal(
                    profileId: otherId,
                    name: profile?.name ?? "Unknown",
                    totalEncounterSeconds: enc.overlapSeconds ?? 0,
                    encounterCount: 1,
                    lastSeenAt: enc.lastSeenAt,
                    isConnected: connectedIds.contains(otherId),
                    sharedInterests: Array(viewerInterests.intersection(theirInterests)),
                    viewerInterests: Array(viewerInterests),
                    theirInterests: Array(theirInterests)
                )
            }
            let insights = InteractionInsightService.shared.generateInsights(from: encounterSignals)
            let insightMap = Dictionary(uniqueKeysWithValues: insights.map { ($0.profileId, $0) })

            for encounter in bestEncounters.values {
                let otherId = encounter.otherProfile(for: myId)
                let actorName = profileMap[otherId]?.name
                let sourceTimestamp = encounter.lastSeenAt ?? encounter.firstSeenAt
                let insight = insightMap[otherId]

                let score = FeedPriorityScorer.scoreEncounter(
                    sourceTimestamp: sourceTimestamp,
                    overlapSeconds: encounter.overlapSeconds,
                    zoneMultiplier: zoneBoost
                )

                let resolvedEventName = encounter.eventId.flatMap { eventNameCache[$0] }

                let metadata = FeedItemMetadata(
                    eventName: resolvedEventName,
                    overlapSeconds: encounter.overlapSeconds,
                    actorName: actorName,
                    insightText: insight?.insightText,
                    needState: insight?.needState.rawValue
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

                _ = try? await supabase
                    .from("feed_items")
                    .upsert(payload, onConflict:
                        "viewer_profile_id,type,actor_profile_id,event_id")
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

    private func generateMessageFeedItems(myId: UUID, zoneBoost: Double = 1.0) async {
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

                let score = FeedPriorityScorer.scoreMessage(sourceTimestamp: latestMessage.createdAt, zoneMultiplier: zoneBoost)

                // Resolve event name from conversation or cache
                let resolvedEventName = convo.eventName
                    ?? convo.eventId.flatMap { eventNameCache[$0] }

                let metadata = FeedItemMetadata(
                    eventName: resolvedEventName,
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
