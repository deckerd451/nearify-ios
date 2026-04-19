import Foundation

// MARK: - Connection Status

enum RelationshipConnectionStatus: String {
    case none
    case pending
    case accepted
}

// MARK: - Relationship Memory

/// Persistent, cumulative understanding of a relationship with another person.
/// Derived entirely from existing persisted data (feed_items, encounters, connections, conversations).
/// No new scoring logic — reuses existing temporal priority model.
struct RelationshipMemory: Identifiable {
    var id: UUID { profileId }
    let profileId: UUID
    let name: String
    let avatarUrl: String?

    // Encounter history (from feed_items + encounters)
    let encounterCount: Int
    let totalOverlapSeconds: Int
    let lastEncounterAt: Date?

    // Connection state (from connections)
    let connectionStatus: RelationshipConnectionStatus
    let connectionDate: Date?

    // Messaging state (from conversations + messages)
    let hasConversation: Bool
    let lastMessageAt: Date?

    // Shared context
    let sharedInterests: [String]
    let eventContexts: [String]

    // Derived signals
    let needsFollowUp: Bool
    let relationshipStrength: Double
    let whyLine: String
}

// MARK: - People Section

/// Structured sections for the People layer.
/// Each section has a clear semantic meaning — not a feed replay.
enum PeopleSection: String, CaseIterable {
    case recent     = "Recent"
    case recurring  = "Recurring"
    case strongest  = "Strongest"
    case followUp   = "Follow Up"
    case connected  = "Connected"

    var icon: String {
        switch self {
        case .recent:    return "clock"
        case .recurring: return "arrow.triangle.2.circlepath"
        case .strongest: return "bolt.fill"
        case .followUp:  return "exclamationmark.bubble"
        case .connected: return "link"
        }
    }
}
