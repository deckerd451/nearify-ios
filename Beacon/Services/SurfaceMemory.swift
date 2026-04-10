import Foundation

/// Lightweight per-item action state tracking for the Home surface.
/// Tracks when items were acted on, dismissed, or cooled down so the
/// surface builder can suppress stale or already-handled prompts.
@MainActor
final class SurfaceMemory {

    static let shared = SurfaceMemory()

    // MARK: - Item State

    struct ItemState {
        var lastActedAt: Date?
        var lastDismissedAt: Date?
        var cooldownUntil: Date?
    }

    // MARK: - Cooldown Durations

    enum Cooldown {
        static let replied: TimeInterval     = .infinity  // permanent removal until next message
        static let findTapped: TimeInterval  = 120        // 2 min cooldown, can resurface
        static let viewedProfile: TimeInterval = 60       // 1 min short cooldown
        static let rejoined: TimeInterval    = .infinity   // permanent removal
        static let connected: TimeInterval   = .infinity   // permanent removal
    }

    // MARK: - State

    /// Keyed by "section:profileId" or "section:eventId" for event items.
    private var states: [String: ItemState] = [:]

    private init() {}

    // MARK: - Public API

    /// Record that the user acted on an item. Applies the appropriate cooldown.
    func recordAction(profileId: UUID?, eventId: UUID?, section: HomeSurfaceSection, actionType: SurfaceActionType) {
        let key = itemKey(profileId: profileId, eventId: eventId, section: section)
        var state = states[key] ?? ItemState()
        state.lastActedAt = Date()

        let duration: TimeInterval
        switch actionType {
        case .reply, .message, .followUp:
            duration = Cooldown.replied
        case .findAttendee:
            duration = Cooldown.findTapped
        case .viewProfile:
            duration = Cooldown.viewedProfile
        case .jumpBack:
            duration = Cooldown.rejoined
        case .connect:
            duration = Cooldown.connected
        }

        if duration == .infinity {
            // Permanent: set cooldown far in the future
            state.cooldownUntil = Date.distantFuture
        } else {
            state.cooldownUntil = Date().addingTimeInterval(duration)
        }

        states[key] = state

        #if DEBUG
        print("[Memory] 📝 Recorded \(actionType.rawValue) for \(key) cooldown=\(duration == .infinity ? "permanent" : "\(Int(duration))s")")
        #endif
    }

    /// Check if an item is currently suppressed (in cooldown or permanently removed).
    func isSuppressed(profileId: UUID?, eventId: UUID?, section: HomeSurfaceSection) -> Bool {
        let key = itemKey(profileId: profileId, eventId: eventId, section: section)
        guard let state = states[key] else { return false }
        guard let cooldown = state.cooldownUntil else { return false }
        return Date() < cooldown
    }

    /// Clear a specific item's suppression (e.g., when a new message arrives).
    func clearSuppression(profileId: UUID?, section: HomeSurfaceSection) {
        let key = itemKey(profileId: profileId, eventId: nil, section: section)
        states[key]?.cooldownUntil = nil
    }

    /// Clear all memory (e.g., on event leave or app reset).
    func reset() {
        states.removeAll()
        #if DEBUG
        print("[Memory] 🧹 Reset all surface memory")
        #endif
    }

    // MARK: - Key Generation

    private func itemKey(profileId: UUID?, eventId: UUID?, section: HomeSurfaceSection) -> String {
        let id = profileId?.uuidString ?? eventId?.uuidString ?? "unknown"
        return "\(section.title):\(id)"
    }
}
