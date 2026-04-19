import SwiftUI
import Combine

/// Lightweight shared navigation state for contextual cross-tab transitions.
/// Used to pass focus targets between tabs without coupling view models.
final class NavigationState: ObservableObject {
    static let shared = NavigationState()

    /// When set, People tab scrolls to, expands, and highlights this person.
    @Published var peopleFocusTarget: PeopleFocusTarget?

    /// When set, People tab filters and prioritizes people relevant to this event.
    /// Cleared automatically when the user leaves the event or navigates away.
    @Published var eventContext: PeopleEventContext?

    // MARK: - Tab Change Cooldown

    /// Minimum interval between programmatic tab changes (prevents thrashing).
    private let tabCooldown: TimeInterval = 1.0
    private var lastTabChangeTime: Date = .distantPast

    private init() {}

    /// Attempts a programmatic tab change with cooldown guard.
    /// Returns true if the change was allowed, false if blocked.
    @discardableResult
    func requestTabChange(from current: AppTab, to target: AppTab, binding: inout AppTab) -> Bool {
        guard current != target else {
            #if DEBUG
            print("[Navigation] BLOCKED (already on \(target))")
            #endif
            return false
        }

        let elapsed = Date().timeIntervalSince(lastTabChangeTime)
        guard elapsed >= tabCooldown else {
            #if DEBUG
            print("[Navigation] BLOCKED (cooldown, \(String(format: "%.1f", elapsed))s < \(tabCooldown)s)")
            #endif
            return false
        }

        lastTabChangeTime = Date()
        binding = target

        #if DEBUG
        print("[Navigation] \(current) → \(target)")
        #endif
        return true
    }
}

/// Describes which person to focus on and where the request originated.
struct PeopleFocusTarget: Equatable {
    let profileId: UUID
    let source: String // "home", "explore", etc.
}

/// Event context injected into the People tab for contextual filtering.
struct PeopleEventContext: Equatable {
    let eventId: String
    let eventName: String
}
