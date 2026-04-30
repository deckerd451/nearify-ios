import Foundation
import Combine
import Supabase
import UIKit

final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var profileState: ProfileState = .missing

    /// True when the app entered using a cached identity because the network
    /// was unavailable at launch. Cleared when online bootstrap succeeds.
    @Published var isOfflineMode = false

    private let supabase = AppEnvironment.shared.supabaseClient
    private var authStateTask: Task<Void, Never>?
    private var networkRecoveryCancellable: AnyCancellable?
    private var networkLossCancellable: AnyCancellable?

    /// Guards against transient nil session events during token refresh.
    /// When we receive a nil/expired session, we wait briefly then re-check
    /// before nuking auth state.
    private let sessionGracePeriod: UInt64 = 1_500_000_000 // 1.5 seconds

    /// Maximum time to wait for the initial profile fetch before falling back
    /// to cached identity. Keeps cold launch snappy on slow/absent networks.
    private let startupProfileTimeout: UInt64 = 6_000_000_000 // 6 seconds

    private init() {
        observeAuthState()
        // Network loss observer must be set up on MainActor
        Task { @MainActor in
            self.observeNetworkLoss()
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    private func observeAuthState() {
        authStateTask?.cancel()

        authStateTask = Task { [weak self] in
            guard let self else { return }

            await self.checkInitialSession()

            for await (event, session) in supabase.auth.authStateChanges {
                print("[Auth] 📡 authStateChange event: \(event)")
                await self.handleAuthStateChange(event: event, session: session)
            }
        }
    }

    private func checkInitialSession() async {
        print("[Startup] attempting online bootstrap")

        // The NetworkMonitor initializes with isOnline=true and updates
        // asynchronously via NWPathMonitor. On cold launch in airplane mode,
        // the monitor may not have fired yet. Give it a brief moment to settle.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let isOnline = await MainActor.run { NetworkMonitor.shared.isOnline }
        let hasCachedIdentity = await MainActor.run { CachedIdentityStore.shared.hasCachedIdentity }

        // Fast path: network is known offline and we have a cached identity.
        // Enter Nearby Mode immediately — no spinner, no waiting.
        if !isOnline && hasCachedIdentity {
            print("[NearbyMode] cold launch fallback engaged")
            print("[NearbyMode] entering from cached identity")
            await enterOfflineMode(reason: "network offline at launch")
            return
        }

        // Attempt normal session + profile bootstrap with a timeout.
        // If the network is slow or unavailable, we fall back to cached identity.
        let bootstrapTask = Task {
            try await self.performOnlineBootstrap()
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: startupProfileTimeout)
            bootstrapTask.cancel()
        }

        do {
            try await bootstrapTask.value
            timeoutTask.cancel()
            // Online bootstrap succeeded — clear any stale offline state
            await MainActor.run {
                self.isOfflineMode = false
            }
            print("[Startup] online bootstrap succeeded")
        } catch is CancellationError {
            timeoutTask.cancel()
            print("[Startup] online bootstrap timed out")
            await enterOfflineMode(reason: "bootstrap timed out")
        } catch {
            timeoutTask.cancel()
            print("[Startup] online bootstrap failed: \(error.localizedDescription)")
            await enterOfflineMode(reason: "bootstrap error: \(error.localizedDescription)")
        }
    }

    /// Performs the standard online session validation and profile load.
    /// Throws on any failure so the caller can fall back to cached identity.
    private func performOnlineBootstrap() async throws {
        let session = try await supabase.auth.session
        if session.isExpired {
            print("[Auth] ⚠️ Initial session exists but is expired, attempting refresh...")
            let refreshed = try await supabase.auth.refreshSession()
            print("[Auth] ✅ Session refreshed, expires: \(refreshed.expiresAt)")
            await loadCurrentUser()
        } else {
            print("[Auth] ✅ Initial session valid, expires: \(session.expiresAt)")
            await loadCurrentUser()
        }

        // If loadCurrentUser succeeded but currentUser is still nil,
        // the profile fetch itself failed — treat as error for fallback purposes.
        let user = await MainActor.run { self.currentUser }
        if user == nil {
            throw BootstrapError.profileLoadFailed
        }
    }

    /// Enters offline mode using cached identity if available.
    /// If no cached identity exists, sets unauthenticated state.
    private func enterOfflineMode(reason: String) async {
        let cachedUser = await MainActor.run {
            CachedIdentityStore.shared.loadCachedUser()
        }
        if let cachedUser {
            print("[Startup] cached profile found: \(cachedUser.name)")
            print("[Startup] entering offline mode with cached identity")
            await MainActor.run {
                self.currentUser = cachedUser
                self.profileState = cachedUser.profileState
                self.isAuthenticated = true
                self.isOfflineMode = true
            }
            await MainActor.run {
                self.observeNetworkRecovery()
            }
        } else {
            print("[Startup] no cached profile available — showing login")
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
                self.isOfflineMode = false
            }
        }
    }

    // MARK: - Network Recovery

    /// Observes network state and retries online bootstrap when connectivity returns.
    /// Automatically leaves offline mode on success.
    @MainActor
    private func observeNetworkRecovery() {
        networkRecoveryCancellable?.cancel()
        networkRecoveryCancellable = NetworkMonitor.shared.$isOnline
            .removeDuplicates()
            .filter { $0 == true }
            .first() // Only need the first online signal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.isOfflineMode else { return }
                print("[Startup] connectivity restored, retrying online bootstrap")
                Task {
                    await self.retryOnlineBootstrap()
                }
            }
    }

    /// Retries the full online bootstrap after network recovery.
    /// On success, replaces the cached identity with the live profile
    /// and clears offline mode. On failure, stays in offline mode silently.
    private func retryOnlineBootstrap() async {
        do {
            try await performOnlineBootstrap()
            await MainActor.run {
                self.isOfflineMode = false
                print("[NearbyMode] exiting (connection restored)")
                // Sync any pending nearby confirmations
                NearbyModeTracker.shared.syncPendingConfirmations()
                NearbyModeTracker.shared.stopTracking()
            }
            print("[Startup] online bootstrap succeeded after recovery — offline mode cleared")
        } catch {
            print("[Startup] online bootstrap retry failed: \(error.localizedDescription) — staying in offline mode")
            // Re-observe for next connectivity change
            await MainActor.run {
                self.observeNetworkRecovery()
            }
        }
    }

    // MARK: - Network Loss Detection

    /// Persistent observer: when network drops during an active session,
    /// immediately enter Nearby Mode. This runs for the lifetime of the service.
    @MainActor
    private func observeNetworkLoss() {
        networkLossCancellable?.cancel()
        networkLossCancellable = NetworkMonitor.shared.$isOnline
            .removeDuplicates()
            .dropFirst() // Skip the initial value — only react to changes
            .receive(on: RunLoop.main)
            .sink { [weak self] isOnline in
                guard let self else { return }

                if !isOnline && self.isAuthenticated && !self.isOfflineMode {
                    // Network just dropped during an active session
                    print("[NearbyMode] network lost during active session")
                    self.isOfflineMode = true
                    print("[NearbyMode] UI switched to Nearby Mode")
                    print("[NearbyMode] backend polling suspended")
                    NearbyModeTracker.shared.startTracking()
                }

                if isOnline && self.isOfflineMode {
                    // Network returned — trigger recovery
                    print("[Startup] connectivity restored, retrying online bootstrap")
                    Task {
                        await self.retryOnlineBootstrap()
                    }
                }
            }
    }

    /// Internal error type for bootstrap failures.
    private enum BootstrapError: Error {
        case profileLoadFailed
    }

    private func handleAuthStateChange(event: AuthChangeEvent, session: Session?) async {
        // If we're already in offline mode, do not let auth state events
        // trigger network calls that will hang. The offline fallback has
        // already set the correct state. Recovery happens via observeNetworkLoss.
        let offline = await MainActor.run { self.isOfflineMode }
        if offline {
            #if DEBUG
            print("[Auth] ℹ️ Ignoring authStateChange '\(event)' — in offline mode")
            #endif
            return
        }

        // Token refresh and signed-in events with a valid session — load profile
        if let session = session, !session.isExpired {
            print("[Auth] 🔑 Valid session for event '\(event)', user: \(session.user.id), expires: \(session.expiresAt)")
            await loadCurrentUser()
            return
        }

        // Explicit sign-out — clear immediately, no grace period
        if event == .signedOut {
            print("[Auth] 👋 Explicit sign-out event received — clearing auth state")
            await clearAuthState(reason: "signedOut event")
            return
        }

        // Session is nil or expired, but this might be a transient token-refresh gap.
        // Wait briefly, then re-check the session before clearing state.
        print("[Auth] ⏳ Session nil/expired for event '\(event)' — entering grace period before clearing state")

        do {
            try await Task.sleep(nanoseconds: sessionGracePeriod)
        } catch {
            return // Task cancelled
        }

        // Re-check: does the SDK now have a valid session?
        do {
            let currentSession = try await supabase.auth.session
            if !currentSession.isExpired {
                print("[Auth] ✅ Session recovered after grace period (expires: \(currentSession.expiresAt)) — keeping auth state")
                return
            }
            print("[Auth] 🔒 Session still expired after grace period — clearing auth state")
        } catch {
            print("[Auth] 🔒 No session after grace period — clearing auth state")
        }

        await clearAuthState(reason: "session nil/expired after grace period")
    }

    private func clearAuthState(reason: String) async {
        print("[Auth] 🔴 Clearing auth state: \(reason)")
        let wasAuthenticated = await MainActor.run { self.isAuthenticated }

        await MainActor.run {
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
        }

        // Stop heartbeats and presence when auth is lost
        if wasAuthenticated {
            print("[Auth] 🛑 Stopping event services due to auth loss")
            await MainActor.run {
                EventPresenceService.shared.stopDueToAuthLoss()
                EventJoinService.shared.stopDueToAuthLoss()
            }
        }
    }

    func signOut() async throws {
        print("[Auth] 👋 signOut() called")
        // Stop services BEFORE signing out to prevent RLS failures
        await MainActor.run {
            EventPresenceService.shared.stopDueToAuthLoss()
            EventJoinService.shared.stopDueToAuthLoss()
        }

        try await supabase.auth.signOut()

        await MainActor.run {
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
            self.isOfflineMode = false
            CachedIdentityStore.shared.clear()
        }
        networkRecoveryCancellable?.cancel()
        networkRecoveryCancellable = nil
        print("[Auth] ✅ Signed out, all state cleared")
    }

    // MARK: - OAuth

    @MainActor
    func signInWithOAuth(provider: Provider) async throws {
        print("[Auth] 🌐 Starting OAuth for provider: \(provider)")
        let url = try supabase.auth.getOAuthSignInURL(
            provider: provider,
            redirectTo: URL(string: "beacon://callback")
        )

        await UIApplication.shared.open(url)
    }

    @MainActor
    func handleOAuthCallback(url: URL) async {
        guard url.absoluteString.hasPrefix("beacon://callback") else {
            print("[Auth] ⚠️ handleOAuthCallback called with non-OAuth URL — rejected: \(url.absoluteString)")
            return
        }
        print("[Auth] 🔗 Processing OAuth callback...")
        do {
            let session = try await supabase.auth.session(from: url)
            print("[Auth] ✅ OAuth session established for user: \(session.user.id), expires: \(session.expiresAt)")
            await loadCurrentUser()
            print("[Auth] 🟢 Post-OAuth state: isAuthenticated=\(isAuthenticated), profileState=\(profileState.rawValue), user=\(currentUser?.name ?? "nil")")
        } catch {
            print("[Auth] ❌ OAuth callback error: \(error)")
            print("[Auth] 🔴 Setting auth state to unauthenticated after OAuth failure")
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
        }
    }

    // MARK: - Profile Loading (reads from public.profiles)

    private func loadCurrentUser() async {
        print("[Auth] 📥 Loading current user from public.profiles...")
        do {
            let result = try await ProfileService.shared.resolveCurrentProfile()

            await MainActor.run {
                self.currentUser = result.profile
                self.profileState = result.state
                self.isAuthenticated = true
            }

            // Cache the profile for offline cold launch fallback
            await MainActor.run {
                CachedIdentityStore.shared.store(
                    user: result.profile,
                    authUserId: result.authUser.id
                )
            }

            print("[Auth] ✅ Profile loaded from public.profiles")
            print("[Auth]    Profile ID: \(result.profile.id)")
            print("[Auth]    State: \(result.state.rawValue)")
            print("[Auth]    Name: \(result.profile.name)")
            print("[Auth]    Avatar URL: \(result.profile.imageUrl ?? "nil")")

            if result.state == .ready {
                MessageNotificationCoordinator.shared.start()
            }

        } catch {
            print("[Auth] ❌ Error loading user from public.profiles: \(error)")

            // Keep isAuthenticated=true if we have a valid session
            // This prevents OAuth buttons from getting stuck/greyed out
            let hasSession: Bool
            do {
                let session = try await supabase.auth.session
                hasSession = !session.isExpired
            } catch {
                hasSession = false
            }

            await MainActor.run {
                self.currentUser = nil
                self.profileState = .missing
                self.isAuthenticated = hasSession
            }
            print("[Auth]    isAuthenticated: \(hasSession) (based on session validity)")
        }
    }

    // MARK: - Profile Refresh

    /// Refreshes the current user profile from public.profiles.
    /// Call after profile edits or avatar uploads to update UI immediately.
    func refreshProfile() async {
        print("[Auth] 🔄 Refreshing profile from public.profiles...")
        await loadCurrentUser()
        print("[Auth] 🔄 Refresh complete. Avatar URL: \(currentUser?.imageUrl ?? "nil"), state: \(profileState.rawValue)")
    }
}
