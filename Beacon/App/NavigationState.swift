import SwiftUI
import Combine
import QuartzCore

enum TabChangeSource {
    case user
    case system
}

enum NavigationTransaction: Equatable {
    case openInNearify
}

/// Lightweight shared navigation state for contextual cross-tab transitions.
/// Used to pass focus targets between tabs without coupling view models.
@MainActor
final class NavigationState: ObservableObject {
    static let shared = NavigationState()

    /// When set, People tab scrolls to, expands, and highlights this person.
    @Published var peopleFocusTarget: PeopleFocusTarget?

    /// When set, People tab filters and prioritizes people relevant to this event.
    /// Cleared automatically when the user leaves the event or navigates away.
    @Published var eventContext: PeopleEventContext?

    /// Global tab route requests for flows that cannot directly access the tab binding.
    @Published var pendingTabRoute: AppTab?
    /// Monotonic signal used to pop the People tab's nested navigation stack to root.
    @Published private(set) var peopleSubrouteResetSignal: Int = 0
    @Published var activeNavigationTransaction: NavigationTransaction?

    private var lastTabWriteSignature: String?
    private var lastTabWriteAt: CFTimeInterval = 0
    private var lastGlobalRouteWriteSignature: String?
    private var lastGlobalRouteWriteAt: CFTimeInterval = 0
    private let sameFrameWriteThreshold: CFTimeInterval = 1.0 / 120.0

    private init() {}

    func requestGlobalTabRoute(to target: AppTab, source: String) {
        guard pendingTabRoute != target else {
            #if DEBUG
            print("[NavigationDebounce] ignored duplicate global route target=\(target) source=\(source)")
            #endif
            return
        }
        let now = CACurrentMediaTime()
        let signature = "\(target.rawValue)-\(source)"
        if signature == lastGlobalRouteWriteSignature, (now - lastGlobalRouteWriteAt) < sameFrameWriteThreshold {
            #if DEBUG
            print("[NavigationFrameGuard] coalesced same-frame global route target=\(target) source=\(source)")
            #endif
            return
        }
        lastGlobalRouteWriteSignature = signature
        lastGlobalRouteWriteAt = now
        #if DEBUG
        let oldValue = pendingTabRoute?.description ?? "nil"
        print("[TabRouting] [TAB-WRITE] \(oldValue) -> \(target) source=\(source) file=NavigationState.requestGlobalTabRoute")
        #endif
        pendingTabRoute = target
    }

    func requestPeopleSubroutePopToRoot() {
        #if DEBUG
        print("[PeopleNav] reset signal increment source=requestPeopleSubroutePopToRoot file=NavigationState")
        #endif
        peopleSubrouteResetSignal &+= 1
    }

    /// Attempts a tab change with source guard.
    /// Only user-driven changes are allowed.
    @discardableResult
    func requestTabChange(
        from current: AppTab,
        to target: AppTab,
        source: TabChangeSource,
        sourceName: String,
        binding: inout AppTab
    ) -> Bool {
        guard current != target else {
            #if DEBUG
            print("[NavigationDebounce] ignored duplicate tab write \(current)→\(target) source=\(sourceName)")
            #endif
            return false
        }

        guard source == .user else {
            #if DEBUG
            print("[TAB-WRITE BLOCKED] system attempted change: \(current) → \(target)")
            #endif
            return false
        }
        
        if activeNavigationTransaction == .openInNearify,
           sourceName != "MainTabView.userTap" {
            #if DEBUG
            print("[TAB-WRITE BLOCKED] transaction=openInNearify blocked \(current) -> \(target) source=\(sourceName)")
            #endif
            return false
        }


        let now = CACurrentMediaTime()
        let signature = "\(current.rawValue)-\(target.rawValue)-\(sourceName)"
        if signature == lastTabWriteSignature, (now - lastTabWriteAt) < sameFrameWriteThreshold {
            #if DEBUG
            print("[NavigationDebounce] ignored same-frame tab write \(current)→\(target) source=\(sourceName)")
            #endif
            return false
        }
        lastTabWriteSignature = signature
        lastTabWriteAt = now

        if target == .event {
            guard EventJoinService.shared.consumeNavigationIntent() else {
                #if DEBUG
                print("[TAB-WRITE BLOCKED] missing navigateToEvent intent: \(current) → \(target)")
                #endif
                return false
            }
        }

        #if DEBUG
        print("[TabRouting] [TAB-WRITE] \(current) -> \(target) source=\(sourceName) file=NavigationState.requestTabChange")
        #endif
        binding = target
        return true
    }
}

extension AppTab: CustomStringConvertible {
    var description: String {
        switch self {
        case .home: return "home"
        case .people: return "people"
        case .event: return "event"
        case .profile: return "profile"
        case .messages: return "messages"
        }
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
