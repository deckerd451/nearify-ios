import Foundation

// MARK: - Person Presence

enum PersonPresence: String {
    case hereNow     = "Here now"
    case notHere     = "Not here right now"
    case followUp    = "Follow up"
}

// MARK: - Presence Source

/// Tracks how a person's "here now" status was determined.
/// BLE is the primary source; backend is secondary.
enum PresenceSource: String {
    case ble              = "BLE"         // Detected via Bluetooth — highest confidence
    case backend          = "backend"     // Confirmed via Supabase event_attendees
    case bleAndBackend    = "BLE+backend" // Both sources agree
    case none             = "none"        // Not present
}

// MARK: - Deep Insight

struct DeepInsight: Identifiable {
    let id = UUID()
    let category: String   // "Interaction", "Relationship", "Suggested Action", "Context"
    let text: String
}

// MARK: - Person Intelligence

/// Unified intelligence model for one person on the People screen.
/// Powers both the visible surface layer and the expandable deep layer.
struct PersonIntelligence: Identifiable {
    let id: UUID               // profileId
    let name: String
    let avatarUrl: String?

    // State
    let presence: PersonPresence
    let presenceSource: PresenceSource
    let connectionStatus: RelationshipConnectionStatus
    let isTargetIntent: Bool   // user was looking for this person

    // Surface layer
    let distilledInsight: String
    let topTraits: [String]
    let whyThisMatters: String?
    let primaryAction: PersonAction
    let secondaryAction: PersonAction?
    let surfacedTraits: [String]
    let hasMeaningfulTimeTogether: Bool

    // Deep layer
    let deepInsights: [DeepInsight]

    // Ranking
    let priorityScore: Double

    // Source data (for actions)
    let liveEventName: String?
    let lastEventName: String?
}

// MARK: - Person Action

enum PersonAction {
    case find
    case message
    case viewProfile
    case keepWatching
    case save

    var label: String {
        switch self {
        case .find:         return "Find"
        case .message:      return "Message"
        case .viewProfile:  return "View Profile"
        case .keepWatching: return "Keep Watching"
        case .save:         return "Save"
        }
    }

    var icon: String {
        switch self {
        case .find:         return "hand.wave"
        case .message:      return "bubble.left"
        case .viewProfile:  return "person"
        case .keepWatching: return "eye"
        case .save:         return "person.crop.circle.badge.plus"
        }
    }
}
