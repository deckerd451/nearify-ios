import Foundation

// MARK: - Post-Event Summary

/// Structured summary generated when a user leaves an event or becomes dormant.
/// Answers: "What happened?" and "What should I do next?"
/// Derived entirely from existing data — no new backend calls.
struct PostEventSummary {
    let eventName: String
    let totalPeopleMet: Int
    let strongestInteraction: ProfileSnapshot?
    let recentConnections: [ProfileSnapshot]
    let missedConnections: [ProfileSnapshot]
    let followUpSuggestions: [FollowUpSuggestion]

    var isEmpty: Bool {
        totalPeopleMet == 0
        && strongestInteraction == nil
        && recentConnections.isEmpty
        && missedConnections.isEmpty
        && followUpSuggestions.isEmpty
    }
}

// MARK: - Profile Snapshot

/// Lightweight profile reference used in summaries.
/// Captures the state at summary generation time.
struct ProfileSnapshot: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let contextLine: String
}

// MARK: - Follow-Up Suggestion

struct FollowUpSuggestion: Identifiable {
    let id: UUID
    let type: SuggestionType
    let targetProfile: ProfileSnapshot
    let reason: String
    let confidence: Double

    enum SuggestionType: String {
        case followUp       = "follow_up"
        case message        = "message"
        case meetNextTime   = "meet_next_time"
    }
}
