import Foundation
import Supabase

/// Canonical profile service. All reads/writes go to public.profiles.
/// Identity mapping: auth.users.id -> profiles.user_id
/// App-facing identity: profiles.id
@MainActor
final class ProfileService {

    static let shared = ProfileService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Resolve Profile

    func resolveCurrentProfile() async throws -> ResolvedProfileResult {
        let session = try await supabase.auth.session
        let authUser = session.user

        print("[Profile] 🔍 Resolving profile from public.profiles")
        print("[Profile]    Auth ID: \(authUser.id)")
        print("[Profile]    Email: \(authUser.email ?? "none")")

        if let profile = try await fetchProfile(userId: authUser.id) {
            print("[Profile] ✅ Existing profile found in public.profiles")
            print("[Profile]    Profile ID: \(profile.id)")
            print("[Profile]    Name: \(profile.name)")
            print("[Profile]    Avatar URL: \(profile.imageUrl ?? "nil")")
            return ResolvedProfileResult(
                authUser: authUser,
                profile: profile,
                state: profile.profileState
            )
        }

        print("[Profile] 📝 No profile found, creating via ensure_profile RPC")

        let profile = try await ensureProfile(authUser: authUser)

        print("[Profile] ✅ Profile ensured: \(profile.id)")

        return ResolvedProfileResult(
            authUser: authUser,
            profile: profile,
            state: profile.profileState
        )
    }

    // MARK: - Fetch Profile

    private func fetchProfile(userId: UUID) async throws -> User? {
        print("[Profile] 📥 Querying public.profiles WHERE user_id = \(userId)")
        do {
            let profiles: [NearifyProfile] = try await supabase
                .from("profiles")
                .select("id,user_id,name,email,avatar_url,bio")
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let profile = profiles.first else {
                print("[Profile] ℹ️ No rows returned from public.profiles for user_id: \(userId)")
                return nil
            }

            print("[Profile] ✅ Row loaded: id=\(profile.id), avatar_url=\(profile.avatar_url ?? "nil")")
            return mapToUser(profile)

        } catch {
            let message = String(describing: error)

            if message.contains("0 rows") || message.contains("PGRST116") {
                print("[Profile] ℹ️ No profile row (PGRST116) for user_id: \(userId)")
                return nil
            }

            print("[Profile] ❌ Fetch from public.profiles failed: \(error)")
            throw error
        }
    }

    // MARK: - Fetch Profile by ID

    /// Loads a profile by profiles.id (the app-facing identity).
    /// Used by ScanView and other features that resolve profiles by ID.
    func fetchProfileById(_ profileId: UUID) async throws -> User? {
        print("[Profile] 📥 Querying public.profiles WHERE id = \(profileId)")
        do {
            let profile: NearifyProfile = try await supabase
                .from("profiles")
                .select("id,user_id,name,email,avatar_url,bio")
                .eq("id", value: profileId.uuidString)
                .single()
                .execute()
                .value

            print("[Profile] ✅ Row loaded: id=\(profile.id), name=\(profile.name ?? "nil")")
            return mapToUser(profile)
        } catch {
            let message = String(describing: error)
            if message.contains("0 rows") || message.contains("PGRST116") {
                print("[Profile] ℹ️ No profile row for id: \(profileId)")
                return nil
            }
            print("[Profile] ❌ Fetch by id from public.profiles failed: \(error)")
            throw error
        }
    }

    // MARK: - Ensure Profile (RPC)

    private func ensureProfile(authUser: Supabase.User) async throws -> User {
        let email = authUser.email ?? "user@example.com"
        let name = email

        let params = EnsureProfileParams(
            p_name: name,
            p_email: email,
            p_avatar_url: ""
        )

        let profile: NearifyProfile = try await supabase
            .rpc("ensure_profile", params: params)
            .execute()
            .value

        return mapToUser(profile)
    }

    // MARK: - Update Profile

    func updateProfile(
        profileId: UUID,
        name: String?,
        bio: String?,
        avatarUrl: String? = nil,
        clearAvatar: Bool = false,
        skills: [String]? = nil,
        interests: [String]? = nil
    ) async throws {
        print("[Profile] 💾 Updating public.profiles row: \(profileId)")
        print("[Profile]    name: \(name ?? "nil")")
        print("[Profile]    bio: \(bio ?? "nil")")
        print("[Profile]    avatar_url: \(clearAvatar ? "(clearing)" : avatarUrl ?? "(unchanged)")")

        let payload = ProfileUpdatePayload(
            name: name,
            bio: bio,
            avatar_url: avatarUrl,
            includeAvatarUrl: avatarUrl != nil || clearAvatar
        )

        try await supabase
            .from("profiles")
            .update(payload)
            .eq("id", value: profileId.uuidString)
            .execute()

        print("[Profile] ✅ public.profiles updated for id: \(profileId)")
    }

    // MARK: - Mapping

    private func mapToUser(_ profile: NearifyProfile) -> User {
        User(
            id: profile.id,
            userId: profile.user_id,
            name: profile.name ?? "User",
            email: profile.email,
            bio: profile.bio,
            skills: nil,
            interests: nil,
            imageUrl: profile.avatar_url,
            imagePath: nil,
            profileCompleted: true,
            connectionCount: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }
}

// MARK: - RPC / Payload Models

private struct EnsureProfileParams: Encodable {
    let p_name: String
    let p_email: String
    let p_avatar_url: String
}

private struct ProfileUpdatePayload: Encodable {
    let name: String?
    let bio: String?
    let avatar_url: String?
    let includeAvatarUrl: Bool

    /// Only encodes avatar_url when explicitly requested (upload or clear).
    /// Prevents name/bio-only edits from accidentally nulling the avatar.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(bio, forKey: .bio)
        if includeAvatarUrl {
            try container.encode(avatar_url, forKey: .avatar_url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, bio, avatar_url
    }
}

// MARK: - Models

struct NearifyProfile: Decodable {
    let id: UUID
    let user_id: UUID
    let name: String?
    let email: String?
    let avatar_url: String?
    let bio: String?
}

struct ResolvedProfileResult {
    let authUser: Supabase.User
    let profile: User
    let state: ProfileState
}
