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
    @Published var peopleContext: PeopleContextRoute?
    /// Monotonic signal used to pop the People tab's nested navigation stack to root.
    @Published private(set) var peopleSubrouteResetSignal: Int = 0
    @Published var activeNavigationTransaction: NavigationTransaction?

    private var lastTabWriteSignature: String?
    private var lastTabWriteAt: CFTimeInterval = 0
    private var lastGlobalRouteWriteSignature: String?
    private var lastGlobalRouteWriteAt: CFTimeInterval = 0
    private var lastObserverApplySignature: String?
    private var lastObserverApplyAt: CFTimeInterval = 0
    private let sameFrameWriteThreshold: CFTimeInterval = 1.0 / 120.0

    private init() {}


    func setPeopleFocusTarget(_ target: PeopleFocusTarget?, source: String) {
        guard peopleFocusTarget != target else {
            DebugLog.verbose("[NavigationNoOp] source=\(source) property=peopleFocusTarget action=skipDuplicate")
            return
        }
        DebugLog.verbose("[NavigationObserverAudit] source=\(source) property=peopleFocusTarget action=write")
        peopleFocusTarget = target
    }

    func setEventContext(_ context: PeopleEventContext?, source: String) {
        guard eventContext != context else {
            DebugLog.verbose("[NavigationNoOp] source=\(source) property=eventContext action=skipDuplicate")
            return
        }
        DebugLog.verbose("[NavigationObserverAudit] source=\(source) property=eventContext action=write")
        eventContext = context
    }

    func requestGlobalTabRoute(to target: AppTab, source: String) {
        guard pendingTabRoute != target else {
            DebugLog.verbose("[NavigationFrameDrop] kind=globalRoute reason=duplicatePending source=\(source) requested=\(target)")
            return
        }
        let now = CACurrentMediaTime()
        let signature = "\(target.rawValue)-\(source)"
        if signature == lastGlobalRouteWriteSignature, (now - lastGlobalRouteWriteAt) < sameFrameWriteThreshold {
            DebugLog.verbose("[NavigationObserverCoalesce] kind=globalRoute source=\(source) requested=\(target) sameFrame=true")
            return
        }
        lastGlobalRouteWriteSignature = signature
        lastGlobalRouteWriteAt = now
        let oldValue = pendingTabRoute?.description ?? "nil"
        DebugLog.verbose("[NavigationFrameWrite] kind=globalRoute allowed=true source=\(source) oldPending=\(oldValue) newPending=\(target)")
        pendingTabRoute = target
    }

    func consumePendingTabRouteIfMatching(_ tab: AppTab, source: String) {
        guard pendingTabRoute == tab else { return }
        DebugLog.verbose("[NavigationFrameWrite] kind=globalRouteConsume allowed=true source=\(source) clearing=\(tab)")
        pendingTabRoute = nil
    }

    func requestPeopleSubroutePopToRoot() {
        DebugLog.verbose("[PathMutation] source=requestPeopleSubroutePopToRoot action=incrementResetSignal")
        peopleSubrouteResetSignal &+= 1
    }

    func setPeopleContext(_ context: PeopleContextRoute?, source: String) {
        guard peopleContext != context else {
            DebugLog.verbose("[NavigationNoOp] source=\(source) property=peopleContext action=skipDuplicate")
            return
        }
        #if DEBUG
        if let context {
            print("[PeopleContext] activeMode=\(context.mode.rawValue)")
        } else {
            print("[PeopleContext] activeMode=none")
        }
        #endif
        peopleContext = context
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
            DebugLog.verbose("[NavigationFrameDrop] kind=tabWrite reason=idempotent source=\(sourceName) currentTab=\(current) requestedTab=\(target)")
            return false
        }

        guard source == .user else {
            DebugLog.diagnostic("[NavigationFailure] blocked system tab change \(current) → \(target) source=\(sourceName)")
            return false
        }
        
        if activeNavigationTransaction == .openInNearify,
           sourceName != "MainTabView.userTap" {
            DebugLog.diagnostic("[NavigationFailure] blocked tab change during openInNearify \(current) -> \(target) source=\(sourceName)")
            return false
        }


        let now = CACurrentMediaTime()
        let signature = "\(current.rawValue)-\(target.rawValue)-\(sourceName)"
        if signature == lastTabWriteSignature, (now - lastTabWriteAt) < sameFrameWriteThreshold {
            DebugLog.verbose("[NavigationObserverCoalesce] kind=tabWrite source=\(sourceName) currentTab=\(current) requestedTab=\(target) sameFrame=true")
            return false
        }
        lastTabWriteSignature = signature
        lastTabWriteAt = now

        if target == .event {
            guard EventJoinService.shared.consumeNavigationIntent() else {
                DebugLog.diagnostic("[NavigationFailure] blocked event tab change without intent \(current) → \(target) source=\(sourceName)")
                return false
            }
        }

        DebugLog.verbose("[NavigationFrameWrite] kind=tabWrite allowed=true source=\(sourceName) currentTab=\(current) requestedTab=\(target)")
        binding = target
        return true
    }

    @discardableResult
    func applyObserverTabRequest(
        current currentTab: AppTab,
        requested requestedTab: AppTab,
        source: String,
        binding: inout AppTab
    ) -> Bool {
        let now = CACurrentMediaTime()
        let signature = "\(currentTab.rawValue)-\(requestedTab.rawValue)-\(source)"
        let sameFrame = signature == lastObserverApplySignature && (now - lastObserverApplyAt) < sameFrameWriteThreshold
        if sameFrame {
            DebugLog.verbose("[NavigationFrameDrop] kind=observerApply reason=sameFrameDuplicate source=\(source) currentTab=\(currentTab) requestedTab=\(requestedTab)")
            return false
        }
        lastObserverApplySignature = signature
        lastObserverApplyAt = now
        return requestTabChange(
            from: currentTab,
            to: requestedTab,
            source: .user,
            sourceName: source,
            binding: &binding
        )
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

enum PeopleContextMode: String, Equatable {
    case liveNearby
    case recurringNearby
    case unfinishedMomentum
    case recommendedNow
    case metBefore
    case strongMatch
    case waitingOnReply
    case followUpNeeded
    case findTarget
    case eventCluster
    case continuityFocus
}

struct PeopleContextRoute: Equatable {
    let mode: PeopleContextMode
    let reason: String
    let eventClusterTag: String?
    let highlightedProfileId: UUID?

    init(mode: PeopleContextMode, reason: String, eventClusterTag: String? = nil, highlightedProfileId: UUID? = nil) {
        self.mode = mode
        self.reason = reason
        self.eventClusterTag = eventClusterTag
        self.highlightedProfileId = highlightedProfileId
    }
}
