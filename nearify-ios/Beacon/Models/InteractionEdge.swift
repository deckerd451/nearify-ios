import Foundation

// MARK: - InteractionEdge

/// Represents a row from public.interaction_edges table
struct InteractionEdge: Codable, Identifiable {
    let id: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let createdAt: Date
    let status: String
    let type: String
    let beaconId: UUID?
    let overlapSeconds: Int?
    let confidence: Double?
    let meta: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case fromUserId = "from_user_id"
        case toUserId = "to_user_id"
        case createdAt = "created_at"
        case status
        case type
        case beaconId = "beacon_id"
        case overlapSeconds = "overlap_seconds"
        case confidence
        case meta
    }
}

// MARK: - SuggestedConnection

/// UI model for a suggested connection based on shared event attendance
struct SuggestedConnection: Identifiable {
    let id: UUID
    let otherUserId: UUID
    let displayName: String
    let sharedEvents: Int
    let lastSeenAt: Date
}
