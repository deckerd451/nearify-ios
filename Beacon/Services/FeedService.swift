import Foundation
import Combine
import Supabase

/// Fetches and manages the Social Memory Feed.
/// Feed items are system-generated from connections, encounters, messages, and suggestions.
/// All profile IDs reference profiles.id (community identity).
@MainActor
final class FeedService: ObservableObject {
    
    static let shared = FeedService()
    
    @Published private(set) var feedItems: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    
    private let supabase = AppEnvironment.shared.supabaseClient
    private var refreshTask: Task<Void, Never>?
    
    private init() {}
    
    // MARK: - Fetch Feed
    
    /// Loads feed items for the current user, sorted by priority_score DESC, then created_at DESC.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            guard let myId = AuthService.shared.currentUser?.id else {
                print("[Feed] ⚠️ No current user, skipping refresh")
                return
            }
            
            isLoading = true
            defer { isLoading = false }
            
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
    }
    
    // MARK: - Generate Feed from Connections
    
    /// Creates feed items from new connections that don't already have feed entries.
    /// Called after a connection is created or on periodic sync.
    func generateConnectionFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        do {
            let connections = try await ConnectionService.shared.fetchConnections()
            
            for conn in connections {
                let other = conn.otherUser(for: myId)
                
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
                    priorityScore: FeedItemType.connection.priorityScore,
                    metadata: metadata,
                    createdAt: nil
                )
                
                // Upsert — skip if already exists for this connection+event
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
    
    // MARK: - Generate Feed from Encounters
    
    func generateEncounterFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        do {
            let encounters: [Encounter] = try await supabase
                .from("encounters")
                .select("*")
                .or("profile_a.eq.\(myId.uuidString),profile_b.eq.\(myId.uuidString)")
                .order("last_seen_at", ascending: false)
                .limit(20)
                .execute()
                .value
            
            #if DEBUG
            print("[Feed] 🔍 Processing \(encounters.count) encounters for feed generation")
            #endif
            
            // Deduplicate encounters by (otherProfileId, eventId) — keep the strongest/most recent
            var bestEncounters: [String: Encounter] = [:]
            for encounter in encounters {
                let otherId = encounter.otherProfile(for: myId)
                let key = "\(otherId)_\(encounter.eventId?.uuidString ?? "nil")"
                
                if let existing = bestEncounters[key] {
                    // Keep the one with more overlap, or more recent last_seen
                    let existingOverlap = existing.overlapSeconds ?? 0
                    let newOverlap = encounter.overlapSeconds ?? 0
                    if newOverlap > existingOverlap {
                        bestEncounters[key] = encounter
                        #if DEBUG
                        print("[Feed] 🔄 Encounter deduped for profile \(otherId): keeping \(newOverlap)s over \(existingOverlap)s")
                        #endif
                    } else {
                        #if DEBUG
                        print("[Feed] ⏭️ Encounter skipped (duplicate, weaker) for profile \(otherId)")
                        #endif
                    }
                } else {
                    bestEncounters[key] = encounter
                }
            }
            
            #if DEBUG
            print("[Feed] 📊 Deduped to \(bestEncounters.count) unique encounters from \(encounters.count) total")
            #endif
            
            for encounter in bestEncounters.values {
                let otherId = encounter.otherProfile(for: myId)
                
                // Resolve the other person's name for display
                var actorName: String? = nil
                if let profile = try? await ProfileService.shared.fetchProfileById(otherId) {
                    actorName = profile.name
                }
                
                // Use the encounter's source timestamp, not feed generation time
                let sourceTimestamp = encounter.lastSeenAt ?? encounter.firstSeenAt
                
                #if DEBUG
                print("[Feed] 📝 Encounter timestamp used: \(sourceTimestamp?.description ?? "nil") for profile \(otherId)")
                #endif
                
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
                    priorityScore: FeedItemType.encounter.priorityScore,
                    metadata: metadata,
                    createdAt: sourceTimestamp
                )
                
                do {
                    try await supabase
                        .from("feed_items")
                        .upsert(payload, onConflict: "viewer_profile_id,type,actor_profile_id,event_id")
                        .execute()
                    
                    #if DEBUG
                    print("[Feed] ✅ Encounter feed item upserted for profile \(otherId) (name: \(actorName ?? "unknown"), overlap: \(encounter.overlapSeconds ?? 0)s)")
                    #endif
                } catch {
                    #if DEBUG
                    print("[Feed] ⚠️ Encounter upsert error for \(otherId): \(error.localizedDescription)")
                    #endif
                }
            }
            
            #if DEBUG
            print("[Feed] ✅ Encounter feed generation complete")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate encounter feed items: \(error)")
        }
    }
    
    // MARK: - Generate Message Feed Items
    
    /// Scans all conversations the current user is part of and creates/updates
    /// a feed item for each conversation with the latest message as preview.
    /// Dedupes by (viewer_profile_id, type=message, actor_profile_id) using
    /// delete-then-insert to avoid NULL event_id unique constraint issues.
    func generateMessageFeedItems() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        do {
            // Fetch all conversations for the current user
            let conversations: [Conversation] = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .execute()
                .value
            
            #if DEBUG
            print("[Feed] 🔍 Processing \(conversations.count) conversations for message feed generation")
            #endif
            
            for convo in conversations {
                // Get the latest message in this conversation
                let messages: [Message] = try await supabase
                    .from("messages")
                    .select("*")
                    .eq("conversation_id", value: convo.id.uuidString)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                
                guard let latestMessage = messages.first else {
                    continue // No messages in this conversation yet
                }
                
                let otherId = convo.otherParticipant(for: myId)
                
                // Resolve the other person's name
                var actorName: String? = nil
                if let profile = try? await ProfileService.shared.fetchProfileById(otherId) {
                    actorName = profile.name
                }
                
                let metadata = FeedItemMetadata(
                    messagePreview: String(latestMessage.content.prefix(80)),
                    conversationId: convo.id.uuidString,
                    actorName: actorName
                )
                
                // Delete existing message feed item for this actor (NULL event_id dedup)
                try await supabase
                    .from("feed_items")
                    .delete()
                    .eq("viewer_profile_id", value: myId.uuidString)
                    .eq("type", value: FeedItemType.message.rawValue)
                    .eq("actor_profile_id", value: otherId.uuidString)
                    .execute()
                
                // Insert fresh with the latest message timestamp
                let payload = FeedItemInsertPayload(
                    viewerProfileId: myId,
                    type: FeedItemType.message.rawValue,
                    actorProfileId: otherId,
                    targetProfileId: nil,
                    eventId: nil,
                    priorityScore: FeedItemType.message.priorityScore,
                    metadata: metadata,
                    createdAt: latestMessage.createdAt
                )
                
                try await supabase
                    .from("feed_items")
                    .insert(payload)
                    .execute()
                
                #if DEBUG
                print("[Feed] ✅ Message feed item upserted for actor \(otherId) (name: \(actorName ?? "unknown"), preview: \"\(String(latestMessage.content.prefix(30)))...\", conversation: \(convo.id))")
                #endif
            }
            
            #if DEBUG
            print("[Feed] ✅ Message feed generation complete")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate message feed items: \(error)")
        }
    }
    
    /// Single-message variant: creates a feed item for one specific message.
    /// Called after sending a message for immediate feed update.
    func generateMessageFeedItem(from message: Message, senderName: String, conversationId: UUID) async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        // For sent messages, the "actor" in the feed is the OTHER person (the recipient)
        // For received messages, the "actor" is the sender
        // We always show the conversation partner as the actor
        let actorId: UUID
        let actorDisplayName: String
        
        if message.senderProfileId == myId {
            // I sent this — actor is whoever I'm talking to
            // We need to look up the conversation to find the other participant
            // For now, use the conversationId to resolve later in bulk generation
            // Just trigger a full message feed refresh instead
            #if DEBUG
            print("[Feed] 📨 Sent message detected, triggering message feed refresh")
            #endif
            await generateMessageFeedItems()
            return
        } else {
            actorId = message.senderProfileId
            actorDisplayName = senderName
        }
        
        let metadata = FeedItemMetadata(
            messagePreview: String(message.content.prefix(80)),
            conversationId: conversationId.uuidString,
            actorName: actorDisplayName
        )
        
        // For messages, we first delete any existing message feed item from this actor
        // then insert fresh. This avoids the NULL event_id unique constraint issue
        // (PostgreSQL treats NULL != NULL in UNIQUE constraints).
        do {
            // Remove stale message card for this actor
            try await supabase
                .from("feed_items")
                .delete()
                .eq("viewer_profile_id", value: myId.uuidString)
                .eq("type", value: FeedItemType.message.rawValue)
                .eq("actor_profile_id", value: actorId.uuidString)
                .execute()
            
            // Insert fresh with the message's actual timestamp
            let payload = FeedItemInsertPayload(
                viewerProfileId: myId,
                type: FeedItemType.message.rawValue,
                actorProfileId: actorId,
                targetProfileId: nil,
                eventId: nil,
                priorityScore: FeedItemType.message.priorityScore,
                metadata: metadata,
                createdAt: message.createdAt
            )
            
            try await supabase
                .from("feed_items")
                .insert(payload)
                .execute()
            
            #if DEBUG
            print("[Feed] ✅ Message feed item created for conversation \(conversationId) (actor: \(actorDisplayName))")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate message feed item: \(error)")
        }
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
        // Only encode createdAt if explicitly set (encounter source timestamps).
        // Otherwise let the DB default (now()) handle it.
        if let createdAt = createdAt {
            try container.encode(createdAt, forKey: .createdAt)
        }
    }
}
