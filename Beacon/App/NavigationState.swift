import SwiftUI
import Combine

enum TabChangeSource {
    case user
    case system
}

/// Lightweight shared navigation state for contextual cross-tab transitions.
/// Used to pass focus targets between tabs without coupling view models.
final class NavigationState: ObservableObject {
    static let shared = NavigationState()

    /// When set, People tab scrolls to, expands, and highlights this person.
    @Published var peopleFocusTarget: PeopleFocusTarget?

    /// When set, People tab filters and prioritizes people relevant to this event.
    /// Cleared automatically when the user leaves the event or navigates away.
    @Published var eventContext: PeopleEventContext?

    private init() {}

    /// Attempts a tab change with source guard.
    /// Only user-driven changes are allowed.
    @discardableResult
    func requestTabChange(
        from current: AppTab,
        to target: AppTab,
        source: TabChangeSource,
        binding: inout AppTab
    ) -> Bool {
        guard current != target else {
            return false
        }

        guard source == .user else {
            #if DEBUG
            print("[TAB-WRITE BLOCKED] system attempted change: \(current) → \(target)")
            #endif
            return false
        }

        if target == .event {
            guard EventJoinService.shared.consumeNavigationIntent() else {
                #if DEBUG
                print("[TAB-WRITE BLOCKED] missing navigateToEvent intent: \(current) → \(target)")
                #endif
                return false
            }
        }

        binding = target
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
