import Foundation
import SwiftUI

// MARK: - Event Participation State
//
// Single canonical state model for event participation.
// Resolves from EventJoinService + BeaconPresenceService + ExploreEventsService.
//
// Precedence (highest to lowest):
//   restoring → checkedIn → nearVenueNotCheckedIn
//   → joinedTodayNotCheckedIn → joinedUpcoming → left → none
//
// Every surface that asks "what is the user doing?" must resolve through here.
// No service or view should independently decide this from raw flags.

enum EventParticipationState: Equatable {
    /// No joined event. Nearby Mode may appear as passive fallback.
    case none
    /// Joined a future event (not happening today). Pre-event preparation.
    case joinedUpcoming
    /// Joined today's event but not physically present / not checked in.
    case joinedTodayNotCheckedIn
    /// At the event venue (beacon confirmed) but not yet checked in. Prompt to check in now.
    case nearVenueNotCheckedIn
    /// Checked in. Heartbeat active. Live event mode.
    case checkedIn
    /// Explicitly left the event. Post-event state.
    case left
    /// Cold-launch restore in progress. Hold brief presentation until backend confirms.
    case restoring

    // MARK: - Behaviour Flags

    /// Whether to show live attendee list and BLE-powered actions.
    var showsLiveAttendees: Bool { self == .checkedIn }

    /// Whether to show pre-event brief content rather than live event mode.
    var showsPreEventBrief: Bool {
        switch self {
        case .joinedTodayNotCheckedIn, .nearVenueNotCheckedIn, .joinedUpcoming: return true
        default: return false
        }
    }

    /// Whether Nearby Mode may appear as a passive fallback surface.
    /// Must be false whenever a valid joined event exists.
    var allowsNearbyModeFallback: Bool {
        switch self {
        case .none, .left: return true
        default: return false
        }
    }

    /// Whether the user holds event membership in the backend (joined in DB).
    var isJoined: Bool {
        switch self {
        case .joinedUpcoming, .joinedTodayNotCheckedIn, .nearVenueNotCheckedIn, .checkedIn: return true
        default: return false
        }
    }

    // MARK: - CTA Language

    var primaryCTA: String {
        switch self {
        case .none:                     return "Join an Event"
        case .joinedUpcoming:           return "Prepare for Event"
        case .joinedTodayNotCheckedIn:  return "Check In When You Arrive"
        case .nearVenueNotCheckedIn:    return "You're Here — Check In Now"
        case .checkedIn:                return "You're Live"
        case .left:                     return "Find Another Event"
        case .restoring:                return ""
        }
    }

    // MARK: - Debug

    var debugLabel: String {
        switch self {
        case .none:                     return "none"
        case .joinedUpcoming:           return "joinedUpcoming"
        case .joinedTodayNotCheckedIn:  return "joinedTodayNotCheckedIn"
        case .nearVenueNotCheckedIn:    return "nearVenueNotCheckedIn"
        case .checkedIn:                return "checkedIn"
        case .left:                     return "left"
        case .restoring:                return "restoring"
        }
    }
}

// MARK: - Resolver

/// Single authority for resolving EventParticipationState from live service signals.
/// Call resolve() at any rendering decision point.
/// Do not cache the result — it is cheap to recompute and must stay fresh.
@MainActor
enum EventParticipationStateResolver {

    /// Resolves state with strict precedence.
    static func resolve() -> EventParticipationState {
        let join = EventJoinService.shared
        let beacon = BeaconPresenceService.shared

        // 1. Startup restore in progress — wait for backend confirmation before
        //    showing brief or live mode. Prevents flicker if membership was revoked.
        if join.isRestoringFromPersist {
            return .restoring
        }

        // 2. Checked in — heartbeat running, BLE active, live event mode.
        if join.isCheckedIn {
            return .checkedIn
        }

        // 3. Dormant — heartbeat paused, membership preserved.
        //    Treat as joined-not-checked-in (not live). User must tap Resume.
        if case .dormant = join.membershipState {
            if let eventId = join.currentEventID, isEventHappeningToday(eventId: eventId) {
                return .joinedTodayNotCheckedIn
            }
            return .joinedUpcoming
        }

        // 4. Joined with beacon zone confirmation — physically at the venue, not checked in.
        if join.isEventJoined, beacon.currentZoneState == .inside {
            return .nearVenueNotCheckedIn
        }

        // 5. Joined — determine if today or a future event.
        if join.isEventJoined {
            if let eventId = join.currentEventID, isEventHappeningToday(eventId: eventId) {
                return .joinedTodayNotCheckedIn
            }
            return .joinedUpcoming
        }

        // 6. Left — post-event, awaiting acknowledgement.
        if case .left = join.membershipState {
            return .left
        }

        // 7. No active event.
        return .none
    }

    // MARK: - Debug Audit Logs

    /// Emits structured audit log lines for the current participation state.
    /// Call on key state transitions (join, check-in, leave, cold launch restore).
    static func logAudit(renderingSurface: String = "unknown") {
        #if DEBUG
        let join = EventJoinService.shared
        let state = resolve()
        print("[EventStateAudit] resolvedState=\(state.debugLabel)")
        print("[EventStateAudit] sourceSignals=isEventJoined:\(join.isEventJoined) isCheckedIn:\(join.isCheckedIn) membershipState:\(membershipLabel(join.membershipState)) isRestoring:\(join.isRestoringFromPersist)")
        print("[EventStateAudit] joinedEventId=\(join.currentEventID ?? "nil")")
        print("[EventStateAudit] checkedInEventId=\(join.isCheckedIn ? (join.currentEventID ?? "nil") : "nil")")
        print("[EventStateAudit] activeAttendeeStatus=\(membershipLabel(join.membershipState))")
        print("[EventStateAudit] renderingSurface=\(renderingSurface)")
        #endif
    }

    // MARK: - Helpers

    private static func isEventHappeningToday(eventId: String) -> Bool {
        let explore = ExploreEventsService.shared

        // Check the user's current joined event slot
        if let current = explore.currentEvent, current.id.uuidString == eventId {
            return true
        }
        // Check live events happening now
        if explore.happeningNow.contains(where: { $0.id.uuidString == eventId }) {
            return true
        }
        // Check upcoming events that start today
        let calendar = Calendar.current
        if let event = explore.upcoming.first(where: { $0.id.uuidString == eventId }),
           let startsAt = event.startsAt,
           calendar.isDateInToday(startsAt) {
            return true
        }
        return false
    }

    private static func membershipLabel(_ state: EventMembershipState) -> String {
        switch state {
        case .notInEvent:        return "notInEvent"
        case .joined(let n):     return "joined(\(n))"
        case .inEvent(let n):    return "inEvent(\(n))"
        case .inactive(let n):   return "inactive(\(n))"
        case .dormant(let n):    return "dormant(\(n))"
        case .left(let n):       return "left(\(n))"
        }
    }
}
