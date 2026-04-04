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

            for await (_, session) in supabase.auth.authStateChanges {
                await self.handleAuthStateChange(session: session)
            }
        }
    }

    private func checkInitialSession() async {
        do {
            let session = try await supabase.auth.session
            await handleAuthStateChange(session: session)
        } catch {
            print("[Auth] ⚠️ No existing session found")
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
            }
        }
    }

    private func handleAuthStateChange(session: Session?) async {
        guard let session = session, !session.isExpired else {
            print("[Auth] 🔒 Session nil or expired — clearing auth state")
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
            }
            return
        }

        print("[Auth] 🔑 Valid session detected for user: \(session.user.id)")
        await loadCurrentUser()
    }

    func signOut() async throws {
        try await supabase.auth.signOut()

        await MainActor.run {
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
        }
        print("[Auth] 👋 Signed out, auth state cleared")
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
            print("[Auth] ✅ OAuth session established for user: \(session.user.id)")
            await loadCurrentUser()
            print("[Auth] 🟢 Post-OAuth state: isAuthenticated=\(isAuthenticated), profileState=\(profileState.rawValue)")
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
            print("[Auth]    isAuthenticated: true")

        } catch {
            print("[Auth] ❌ Error loading user from public.profiles: \(error)")
            print("[Auth] 🔴 Profile load failed — setting isAuthenticated=true (session valid) but currentUser=nil")

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
