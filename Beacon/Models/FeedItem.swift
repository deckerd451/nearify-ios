import Foundation

// MARK: - FeedItemType

enum FeedItemType: String, Codable, CaseIterable {
    case connection
    case encounter
    case suggestion
    case message
}

// MARK: - FeedItem

/// Decoded row from the `feed_items` table.
/// All profile IDs reference `profiles.id` (community identity).
struct FeedItem: Codable, Identifiable {
    let id: UUID
    let viewerProfileId: UUID
    let type: String
    let actorProfileId: UUID?
    let targetProfileId: UUID?
    let eventId: UUID?
    let createdAt: Date?
    let priorityScore: Double?
    let metadata: FeedItemMetadata?
    
    enum CodingKeys: String, CodingKey {
        case id
        case viewerProfileId  = "viewer_profile_id"
        case type
        case actorProfileId   = "actor_profile_id"
        case targetProfileId  = "target_profile_id"
        case eventId          = "event_id"
        case createdAt        = "created_at"
        case priorityScore    = "priority_score"
        case metadata
    }
    
    var feedType: FeedItemType {
        FeedItemType(rawValue: type) ?? .encounter
    }
}

// MARK: - FeedItemMetadata

/// Flexible metadata stored as JSONB in feed_items.metadata
struct FeedItemMetadata: Codable {
    var eventName: String?
    var sharedInterests: [String]?
    var overlapSeconds: Int?
    var messagePreview: String?
    var conversationId: String?
    var actorName: String?
    var actorAvatarUrl: String?
    var targetName: String?
    var targetAvatarUrl: String?
    var suggestionReason: String?
    
    enum CodingKeys: String, CodingKey {
        case eventName        = "event_name"
        case sharedInterests  = "shared_interests"
        case overlapSeconds   = "overlap_seconds"
        case messagePreview   = "message_preview"
        case conversationId   = "conversation_id"
        case actorName        = "actor_name"
        case actorAvatarUrl   = "actor_avatar_url"
        case targetName       = "target_name"
        case targetAvatarUrl  = "target_avatar_url"
        case suggestionReason = "suggestion_reason"
    }
}
