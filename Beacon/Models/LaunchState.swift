import Foundation

// MARK: - Launch State
//
// Central resolver for the app's launch experience.
// Determines what the user sees on Home based on their context depth.
//
// Two modes:
//   1. ORIENTATION (newUser, signedInNoHistory) → explain the app
//   2. LIVE CONTEXT (returning*) → show what's happening now
//
// Resolved at app startup and on every Home appearance.
// Reads from existing services — no new data sources.

enum LaunchState: String {
    /// Not authenticated. Show onboarding with sign-in.
    case newUser
    /// Authenticated but no prior event history. Guide to first event.
    case signedInNoHistory
    /// Has history but no active event right now. Offer rejoin.
    case returningNoActiveEvent
    /// In an active event but not inside the zone (no anchor).
    case returningActiveEvent
    /// Inside the event — anchor confirmed. Highest-value state.
    case returningInsideEvent
}

// MARK: - Entry Intent
//
// Maps LaunchState to a user-facing intent.
// Used to decide the narrative tone of the Home screen.

enum EntryIntent {
    /// New or no-history user: explain the app, guide to first event.
    case explainAndJoin
    /// Returning user with past context: offer to resume.
    case resumeContext
    /// User is in a live event: show real-time guidance.
    case liveGuidance
}

// MARK: - Resolver

@MainActor
enum LaunchStateResolver {

    /// Computes the current launch state from existing service state.
    static var current: LaunchState {
        let auth = AuthService.shared
        let eventJoin = EventJoinService.shared
        let presence = UserPresenceStateResolver.current
        let feedItems = FeedService.shared.feedItems

        // 1. Not authenticated
        guard auth.isAuthenticated, auth.currentUser != nil else {
            return .newUser
        }

        // 2. Authenticated but no event history
        let hasHistory = !feedItems.isEmpty || eventJoin.reconnectContext != nil
        if !hasHistory && !eventJoin.isEventJoined {
            return .signedInNoHistory
        }

        // 3. Not in an active event but has history
        if !eventJoin.isEventJoined {
            return .returningNoActiveEvent
        }

        // 3b. Dormant — still a member but heartbeat paused
        if case .dormant = eventJoin.membershipState {
            return .returningNoActiveEvent
        }

        // 4. In active event — check zone
        if presence == .insideEvent {
            return .returningInsideEvent
        }

        return .returningActiveEvent
    }

    /// The user-facing intent derived from launch state.
    static var intent: EntryIntent {
        switch current {
        case .newUser, .signedInNoHistory:
            return .explainAndJoin
        case .returningNoActiveEvent:
            return .resumeContext
        case .returningActiveEvent, .returningInsideEvent:
            return .liveGuidance
        }
    }

    /// Whether the Home screen has enough data to render its final state.
    /// Used to gate rendering and prevent state thrashing during async load.
    ///
    /// Returns true when:
    ///   - User is in a live event (state is immediately known from EventJoinService)
    ///   - OR feed data has been loaded at least once
    ///   - OR user has no history (nothing to wait for)
    ///   - OR app is in offline mode (don't wait for network data that won't arrive)
    static var isReady: Bool {
        let eventJoin = EventJoinService.shared
        let feedService = FeedService.shared

        // Live event — state is known immediately, no need to wait for feed
        if eventJoin.isEventJoined { return true }

        // Feed has loaded at least once — we can make routing decisions
        if feedService.lastRefresh != nil { return true }

        // Offline mode — don't wait for network data that won't arrive
        if AuthService.shared.isOfflineMode { return true }

        // No history possible (new user) — ready immediately
        if !AuthService.shared.isAuthenticated { return true }

        return false
    }
}
