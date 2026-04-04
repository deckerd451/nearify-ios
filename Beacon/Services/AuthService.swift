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
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
            }
        }
    }

    private func handleAuthStateChange(session: Session?) async {
        guard let session = session, !session.isExpired else {
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.profileState = .missing
            }
            return
        }

        await loadCurrentUser()
    }

    func signOut() async throws {
        try await supabase.auth.signOut()

        await MainActor.run {
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
        }
    }

    // MARK: - OAuth

    @MainActor
    func signInWithOAuth(provider: Provider) async throws {
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
        do {
            _ = try await supabase.auth.session(from: url)
            await loadCurrentUser()
        } catch {
            print("[Auth] ❌ OAuth callback error: \(error)")
            self.isAuthenticated = false
            self.currentUser = nil
            self.profileState = .missing
        }
    }

    private func loadCurrentUser() async {
        do {
            let session = try await supabase.auth.session
            
            // Use CommunityIdentityService for canonical profile resolution
            // This reads from the community table where image_url is persisted
            let result = try await CommunityIdentityService.shared.resolveOrCreateProfile(for: session)
            
            switch result {
            case .resolved(let profile):
                await MainActor.run {
                    self.currentUser = profile
                    self.profileState = profile.profileState
                    self.isAuthenticated = true
                }
                
                #if DEBUG
                print("[Auth] ✅ Profile loaded from community table")
                print("[Auth]    State: \(profile.profileState.rawValue)")
                print("[Auth]    Name: \(profile.name)")
                print("[Auth]    Avatar URL: \(profile.imageUrl ?? "nil")")
                #endif
                
            case .ambiguous(let candidates):
                // Use first candidate as fallback
                if let first = candidates.first {
                    await MainActor.run {
                        self.currentUser = first
                        self.profileState = first.profileState
                        self.isAuthenticated = true
                    }
                    
                    #if DEBUG
                    print("[Auth] ⚠️ Ambiguous profile resolution, using first of \(candidates.count) candidates")
                    #endif
                } else {
                    await MainActor.run {
                        self.currentUser = nil
                        self.profileState = .missing
                        self.isAuthenticated = true
                    }
                }
            }
            
        } catch {
            print("[Auth] ❌ Error loading user: \(error)")
            
            await MainActor.run {
                self.currentUser = nil
                self.profileState = .missing
                self.isAuthenticated = false
            }
        }
    }
    
    // MARK: - Profile Refresh
    
    /// Refreshes the current user profile after updates.
    /// Reloads from the community table to pick up avatar URL changes.
    func refreshProfile() async {
        print("[Auth] 🔄 Refreshing profile...")
        await loadCurrentUser()
        print("[Auth] 🔄 Profile refresh complete. Avatar URL: \(currentUser?.imageUrl ?? "nil")")
    }
}
