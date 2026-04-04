import Foundation
import Combine
import Supabase
import UIKit

final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var profileState: ProfileState = .missing

    private let supabase = AppEnvironment.shared.supabaseClient
    private var authStateTask: Task<Void, Never>?

    /// Guards against transient nil session events during token refresh.
    /// When we receive a nil/expired session, we wait briefly then re-check
    /// before nuking auth state.
    private let sessionGracePeriod: UInt64 = 1_500_000_000 // 1.5 seconds

    private init() {
        observeAuthState()
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
        print("[Auth] 🔍 Checking initial session...")
        do {
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
        } catch {
            print("[Auth] ⚠️ No existing session: \(error.localizedDescription)")
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
            }
        }
    }

    private func handleAuthStateChange(event: AuthChangeEvent, session: Session?) async {
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
        }
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

            print("[Auth] ✅ Profile loaded from public.profiles")
            print("[Auth]    Profile ID: \(result.profile.id)")
            print("[Auth]    State: \(result.state.rawValue)")
            print("[Auth]    Name: \(result.profile.name)")
            print("[Auth]    Avatar URL: \(result.profile.imageUrl ?? "nil")")

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
