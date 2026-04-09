import Foundation
import Combine
import SwiftUI

// MARK: - Canonical Event Membership State

/// The five canonical states for event membership.
/// Every user can answer: "Am I in the event?" by looking at this.
enum EventMembershipState: Equatable {
    /// User has not joined any event.
    case notInEvent
    /// User has joined and heartbeat is active.
    case inEvent(eventName: String)
    /// User is temporarily backgrounded but still within the grace window.
    case inactive(eventName: String)
    /// User explicitly tapped "Leave Event".
    case left(eventName: String)
    /// User exceeded inactivity threshold and was automatically removed.
    case timedOut(eventName: String)
}

extension EventMembershipState {

    var isParticipating: Bool {
        switch self {
        case .inEvent, .inactive: return true
        case .notInEvent, .left, .timedOut: return false
        }
    }

    var eventName: String? {
        switch self {
        case .notInEvent: return nil
        case .inEvent(let n), .inactive(let n), .left(let n), .timedOut(let n): return n
        }
    }

    /// User-facing label shown in the event header.
    var displayLabel: String {
        switch self {
        case .notInEvent:       return "No Active Event"
        case .inEvent:          return "Active now"
        case .inactive:         return "Paused — tap to resume"
        case .left:             return "You left this event"
        case .timedOut:         return "Timed out due to inactivity"
        }
    }

    /// SF Symbol for the state indicator dot.
    var iconName: String {
        switch self {
        case .notInEvent:   return "circle"
        case .inEvent:      return "circle.fill"
        case .inactive:     return "moon.fill"
        case .left:         return "arrow.right.circle.fill"
        case .timedOut:     return "clock.badge.xmark"
        }
    }

    /// Color for the state indicator.
    var displayColor: Color {
        switch self {
        case .notInEvent:   return .gray
        case .inEvent:      return .green
        case .inactive:     return .orange
        case .left:         return .red
        case .timedOut:     return .red
        }
    }
}

// MARK: - Event Mode State (View Model)

/// Unified view model for Event Mode screen.
/// Single source of truth for user-facing event status — replaces
/// reading from 6+ observed objects directly in the view.
///
/// Primary status is derived from:
///   1. EventJoinService (QR join state — authoritative)
///   2. AttendeeStateResolver + EventAttendeesService (resolved peers)
///   3. BLEScannerService (raw BLE peer count)
///
/// BeaconConfidenceService is intentionally excluded from user-facing
/// status. It remains available for the diagnostics section only.
@MainActor
final class EventModeState: ObservableObject {

    static let shared = EventModeState()

    // MARK: - Published State

    @Published private(set) var membership: EventMembershipState = .notInEvent
    @Published private(set) var nearbyResolvedCount: Int = 0
    @Published private(set) var activeAttendeeCount: Int = 0
    @Published private(set) var blePeerCount: Int = 0

    /// Legacy compatibility — views that check `status` still compile.
    var status: EventStatus {
        switch membership {
        case .notInEvent, .left, .timedOut:
            return BLEService.shared.isScanning ? .scanningForEvent : .idle
        case .inEvent(let name):
            if nearbyResolvedCount > 0 || blePeerCount > 0 {
                return .joinedWithNearby(eventName: name, nearbyCount: max(nearbyResolvedCount, blePeerCount))
            }
            return .joinedLooking(eventName: name)
        case .inactive(let name):
            return .joinedLooking(eventName: name)
        }
    }

    // MARK: - Dependencies

    private let eventJoin = EventJoinService.shared
    private let attendees = EventAttendeesService.shared
    private let resolver = AttendeeStateResolver.shared
    private let scanner = BLEScannerService.shared

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // MARK: - Status Enum (legacy compatibility)

    enum EventStatus: Equatable {
        case idle
        case scanningForEvent
        case joinedLooking(eventName: String)
        case joinedWithNearby(eventName: String, nearbyCount: Int)
    }

    // MARK: - Init

    private init() {
        startObserving()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Observation

    private func startObserving() {
        eventJoin.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        attendees.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        scanner.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recalculate() }
        }
    }

    // MARK: - Recalculation

    private func recalculate() {
        let resolved = resolver.resolvedPeerDevices(attendees: attendees.attendees)
        let resolvedCount = resolved.count
        let attendeeCount = attendees.attendeeCount
        let bcnPeers = scanner.getKnownBeacons().filter { $0.name.hasPrefix("BCN-") }.count

        nearbyResolvedCount = resolvedCount
        activeAttendeeCount = attendeeCount
        blePeerCount = bcnPeers

        // Membership state is driven by EventJoinService — the single authority.
        membership = eventJoin.membershipState
    }

    // MARK: - Summary Text

    var attendeeSummaryText: String {
        let nearby = nearbyResolvedCount
        let active = activeAttendeeCount

        if attendees.isLoading && active == 0 {
            return "Looking for nearby attendees…"
        }
        if active == 0 && nearby == 0 {
            return "No nearby attendees yet"
        }

        var parts: [String] = []
        if nearby > 0 {
            parts.append("\(nearby) nearby now")
        }
        if active > 0 && active != nearby {
            parts.append("\(active) active in event")
        }
        return parts.joined(separator: " · ")
    }
}
