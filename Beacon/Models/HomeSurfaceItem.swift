import Foundation

// MARK: - Home Surface Section

/// The three sections of the intelligence surface, in strict render order.
enum HomeSurfaceSection: Int, CaseIterable {
    case `continue` = 0
    case insights   = 1
    case nextMoves  = 2

    var title: String {
        switch self {
        case .continue:  return "Continue"
        case .insights:  return "Insights"
        case .nextMoves: return "Next Moves"
        }
    }

    var icon: String {
        switch self {
        case .continue:  return "bolt.fill"
        case .insights:  return "lightbulb.fill"
        case .nextMoves: return "arrow.right.circle.fill"
        }
    }
}

// MARK: - Surface Action Type

/// Explicit action routing types. Each case maps to exactly one navigation flow.
/// Do NOT infer routing from connection status or other item properties.
enum SurfaceActionType: String {
    case findAttendee = "Find Attendee"  // → find-attendee sheet (live proximity)
    case message      = "Message"        // → conversation sheet
    case reply        = "Reply"          // → conversation sheet
    case followUp     = "Follow up"      // → conversation sheet
    case connect      = "Connect"        // → create connection
    case jumpBack     = "Jump back in"   // → switch to Event tab
    case viewProfile  = "View Profile"   // → profile detail push
}

// MARK: - Home Surface Item

/// A single item on the intelligence surface.
struct HomeSurfaceItem: Identifiable {
    let id = UUID()
    let section: HomeSurfaceSection
    let profileId: UUID?
    let name: String
    let headline: String          // Action-first copy: "Doug is nearby — go say hi"
    let subtitle: String?         // Optional context: "Met at Hacker Theater"
    let actionType: SurfaceActionType
    let actionLabel: String       // Button text
    let temporalState: TemporalState
    let priority: Double          // time_decay × signal_strength
    let eventId: UUID?
    let eventName: String?
    let conversationId: UUID?
    let isFind: Bool              // Elevate find-attendee as primary action

    init(
        section: HomeSurfaceSection,
        profileId: UUID?,
        name: String,
        headline: String,
        subtitle: String? = nil,
        actionType: SurfaceActionType,
        actionLabel: String? = nil,
        temporalState: TemporalState,
        priority: Double,
        eventId: UUID? = nil,
        eventName: String? = nil,
        conversationId: UUID? = nil,
        isFind: Bool = false
    ) {
        self.section = section
        self.profileId = profileId
        self.name = name
        self.headline = headline
        self.subtitle = subtitle
        self.actionType = actionType
        self.actionLabel = actionLabel ?? actionType.rawValue
        self.temporalState = temporalState
        self.priority = priority
        self.eventId = eventId
        self.eventName = eventName
        self.conversationId = conversationId
        self.isFind = isFind
    }
}
