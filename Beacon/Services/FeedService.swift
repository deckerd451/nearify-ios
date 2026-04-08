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
                    metadata: metadata
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
            
            for encounter in encounters {
                let otherId = encounter.otherProfile(for: myId)
                
                let metadata = FeedItemMetadata(
                    overlapSeconds: encounter.overlapSeconds
                )
                
                let payload = FeedItemInsertPayload(
                    viewerProfileId: myId,
                    type: FeedItemType.encounter.rawValue,
                    actorProfileId: otherId,
                    targetProfileId: nil,
                    eventId: encounter.eventId,
                    priorityScore: FeedItemType.encounter.priorityScore,
                    metadata: metadata
                )
                
                try await supabase
                    .from("feed_items")
                    .upsert(payload, onConflict: "viewer_profile_id,type,actor_profile_id,event_id")
                    .execute()
            }
            
            #if DEBUG
            print("[Feed] ✅ Generated encounter feed items for \(encounters.count) encounters")
            #endif
        } catch {
            print("[Feed] ❌ Failed to generate encounter feed items: \(error)")
        }
    }
    
    // MARK: - Generate Message Feed Items
    
    func generateMessageFeedItem(from message: Message, senderName: String, conversationId: UUID) async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        guard message.senderProfileId != myId else { return } // Don't notify self
        
        let metadata = FeedItemMetadata(
            messagePreview: String(message.content.prefix(80)),
            conversationId: conversationId.uuidString,
            actorName: senderName
        )
        
        // For messages, we first delete any existing message feed item from this sender
        // then insert fresh. This avoids the NULL event_id unique constraint issue
        // (PostgreSQL treats NULL != NULL in UNIQUE constraints).
        do {
            // Remove stale message card from this sender
            try await supabase
                .from("feed_items")
                .delete()
                .eq("viewer_profile_id", value: myId.uuidString)
                .eq("type", value: FeedItemType.message.rawValue)
                .eq("actor_profile_id", value: message.senderProfileId.uuidString)
                .execute()
            
            // Insert fresh
            let payload = FeedItemInsertPayload(
                viewerProfileId: myId,
                type: FeedItemType.message.rawValue,
                actorProfileId: message.senderProfileId,
                targetProfileId: nil,
                eventId: nil,
                priorityScore: FeedItemType.message.priorityScore,
                metadata: metadata
            )
            
            try await supabase
                .from("feed_items")
                .insert(payload)
                .execute()
            
            #if DEBUG
            print("[Feed] ✅ Generated message feed item from \(senderName)")
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
    
    enum CodingKeys: String, CodingKey {
        case viewerProfileId  = "viewer_profile_id"
        case type
        case actorProfileId   = "actor_profile_id"
        case targetProfileId  = "target_profile_id"
        case eventId          = "event_id"
        case priorityScore    = "priority_score"
        case metadata
    }
}
