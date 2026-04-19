import Foundation

// MARK: - Event Crowd State
//
// Single source of truth for attendee-count-based UI branching.
// Every system that changes behavior based on "how many people are here"
// MUST use this enum instead of raw count comparisons.
//
// Derived from EventAttendeesService.liveOtherCount (excludes self, requires isHereNow).

enum EventCrowdState: String {
    /// No other live attendees. User is alone.
    case empty    // 0
    /// Exactly one other person. Direct interaction.
    case single   // 1
    /// Two other people. Small group, early dynamics.
    case pair     // 2
    /// Three or more. Active event with choices.
    case group    // 3+
}

// MARK: - Resolver

@MainActor
enum EventCrowdStateResolver {

    /// Computes the current crowd state from the canonical live attendee count.
    /// This is the ONLY place where count thresholds are defined.
    static var current: EventCrowdState {
        let count = EventAttendeesService.shared.liveOtherCount
        switch count {
        case 0:     return .empty
        case 1:     return .single
        case 2:     return .pair
        default:    return .group
        }
    }

    /// The raw count, for display purposes only (e.g. "{N} people are here").
    /// Do NOT use this for UI branching — use `current` instead.
    static var count: Int {
        EventAttendeesService.shared.liveOtherCount
    }
}
