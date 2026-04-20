import Foundation
import SwiftUI

// MARK: - User Presence State
//
// Unified concept that drives all user-facing UI and feed behavior.
// Derived from:
//   - EventJoinService (participation)
//   - BeaconPresenceService (anchor zone)
//   - BLEScannerService (peer BLE)
//   - EventAttendeesService (attendee count)
//
// This replaces reading raw BLE flags or beacon terms in the UI layer.
// Technical details stay in Intelligence Debug; user-facing surfaces use this.

enum UserPresenceState: Equatable {
    /// User is physically inside the event space (anchor detected + joined).
    case insideEvent
    /// User is joined and the event is active, but no anchor confirmation.
    /// Peers may or may not be detected yet.
    case activeNow
    /// User is joined and nearby attendees have been detected via BLE,
    /// but no anchor confirmation.
    case nearbyOnly
    /// User is not at any event, or no signals present.
    case notPresent
}

// MARK: - Resolver

/// Computes UserPresenceState from existing service state.
/// Lightweight — reads published properties, no new data sources.
@MainActor
enum UserPresenceStateResolver {

    static var current: UserPresenceState {
        let isJoined = EventJoinService.shared.isCheckedIn
        let zoneState = BeaconPresenceService.shared.currentZoneState
        let isScanning = BLEScannerService.shared.isScanning
        let hasNearbyPeers = EventModeState.shared.blePeerCount > 0

        guard isJoined else { return .notPresent }

        // Anchor zone confirmed — strongest signal
        if zoneState == .inside {
            return .insideEvent
        }

        // Scanning with detected peers — good signal, no anchor
        if isScanning && hasNearbyPeers {
            return .nearbyOnly
        }

        // Joined and scanning (or heartbeat active) but no peers yet
        return .activeNow
    }

    // MARK: - User-Facing Copy

    /// Status line for Profile / Event Status card.
    static var statusText: String {
        switch current {
        case .insideEvent: return "You're inside the event"
        case .activeNow:   return "Active now"
        case .nearbyOnly:  return "Nearby attendees detected"
        case .notPresent:  return ""
        }
    }

    /// Optional subtext for the status line.
    static var statusSubtext: String? {
        switch current {
        case .insideEvent: return "Verified by host device"
        case .activeNow:   return nil
        case .nearbyOnly:  return nil
        case .notPresent:  return nil
        }
    }

    /// SF Symbol for the status indicator.
    static var statusIcon: String {
        switch current {
        case .insideEvent: return "location.fill"
        case .activeNow:   return "circle.fill"
        case .nearbyOnly:  return "antenna.radiowaves.left.and.right"
        case .notPresent:  return "circle"
        }
    }

    /// Color for the status indicator.
    static var statusColor: Color {
        switch current {
        case .insideEvent: return .green
        case .activeNow:   return .green
        case .nearbyOnly:  return .blue
        case .notPresent:  return .gray
        }
    }

    /// Explore tab: live indicator text on the current event card.
    static var exploreLiveIndicator: String {
        switch current {
        case .insideEvent: return "Inside the event"
        case .activeNow:   return "Active now"
        case .nearbyOnly:  return "Active now"
        case .notPresent:  return "Active now"
        }
    }

    /// Explore tab: attendee count label on the current event card.
    static func exploreAttendeeLabel(count: Int) -> String {
        switch current {
        case .insideEvent:
            return count > 0 ? "Inside event · \(count) nearby" : "Inside event"
        case .activeNow:
            return count > 0 ? "\(count) nearby" : ""
        case .nearbyOnly:
            return count > 0 ? "\(count) nearby" : ""
        case .notPresent:
            return count > 0 ? "\(count) nearby" : ""
        }
    }

    // MARK: - Action Language

    /// Contextual action label for "go say hi" type actions.
    /// When inside the event, language is more immediate and decisive.
    static func meetActionLabel(name: String, hasEncounter: Bool) -> String {
        switch current {
        case .insideEvent:
            if hasEncounter {
                return "You've been near \(name) — go say hi"
            }
            return "You're both here — go say hi"
        case .activeNow, .nearbyOnly, .notPresent:
            return "Go say hi"
        }
    }

    /// Short action label for feed card buttons (space-constrained).
    static var shortMeetLabel: String {
        current == .insideEvent ? "They're here — say hi" : "Go say hi"
    }

    // MARK: - Home Context

    /// Whether the Home feed should prioritize real-time opportunities.
    static var isRealTimePriority: Bool {
        current == .insideEvent || current == .nearbyOnly
    }

    /// Home event context strip: presence qualifier shown after event name.
    static var homePresenceQualifier: String? {
        switch current {
        case .insideEvent: return "You're here"
        case .activeNow:   return nil
        case .nearbyOnly:  return nil
        case .notPresent:  return nil
        }
    }

    // MARK: - Feed Scoring

    /// Computes the zone-aware multiplier for feed scoring.
    /// Call this on the main actor, then pass the result into FeedPriorityScorer methods.
    static var feedZoneMultiplier: Double {
        current == .insideEvent ? 1.4 : 1.0
    }

    /// Computes the zone-aware suppression factor for low-priority items.
    /// Call this on the main actor, then pass the result into FeedPriorityScorer methods.
    static var feedZoneSuppression: Double {
        current == .insideEvent ? 0.6 : 1.0
    }
}
