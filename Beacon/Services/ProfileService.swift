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
                .select("id,user_id,name,email,avatar_url,bio,skills,interests,public_email,public_phone,linkedin_url,website_url,share_email,share_phone,preferred_contact_method")
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let profile = profiles.first else {
                print("[Profile] ℹ️ No rows returned from public.profiles for user_id: \(userId)")
                return nil
            }

            print("[Profile] ✅ Row loaded: id=\(profile.id), avatar_url=\(profile.avatar_url ?? "nil"), skills=\(profile.skills ?? []), interests=\(profile.interests ?? [])")
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
                .select("id,user_id,name,email,avatar_url,bio,skills,interests,public_email,public_phone,linkedin_url,website_url,share_email,share_phone,preferred_contact_method")
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

    // MARK: - Batch Fetch Profiles by IDs

    /// Loads multiple profiles in a single query using id IN (...).
    /// Returns a dictionary keyed by profile ID for O(1) lookup.
    func fetchProfilesByIds(_ profileIds: [UUID]) async -> [UUID: User] {
        guard !profileIds.isEmpty else { return [:] }

        let uniqueIds = Array(Set(profileIds))

        #if DEBUG
        print("[Profile] 📥 Batch querying \(uniqueIds.count) profiles")
        #endif

        do {
            let profiles: [NearifyProfile] = try await supabase
                .from("profiles")
                .select("id,user_id,name,email,avatar_url,bio,skills,interests,public_email,public_phone,linkedin_url,website_url,share_email,share_phone,preferred_contact_method")
                .in("id", values: uniqueIds.map { $0.uuidString })
                .execute()
                .value

            var result: [UUID: User] = [:]
            for profile in profiles {
                result[profile.id] = mapToUser(profile)
            }

            #if DEBUG
            print("[Profile] ✅ Batch loaded \(result.count) profiles")
            #endif

            return result
        } catch {
            print("[Profile] ❌ Batch fetch failed: \(error)")
            return [:]
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
        interests: [String]? = nil,
        publicEmail: String? = nil,
        publicPhone: String? = nil,
        linkedInUrl: String? = nil,
        websiteUrl: String? = nil,
        shareEmail: Bool? = nil,
        sharePhone: Bool? = nil,
        preferredContactMethod: String? = nil
    ) async throws {
        print("[Profile] 💾 Updating public.profiles row: \(profileId)")
        print("[Profile]    name: \(name ?? "nil")")
        print("[Profile]    bio: \(bio ?? "nil")")
        print("[Profile]    avatar_url: \(clearAvatar ? "(clearing)" : avatarUrl ?? "(unchanged)")")
        print("[Profile]    skills: \(skills ?? [])")
        print("[Profile]    interests: \(interests ?? [])")
        print("[Profile]    public_email: \(publicEmail ?? "nil")")
        print("[Profile]    public_phone: \(publicPhone ?? "nil")")
        print("[Profile]    linkedin_url: \(linkedInUrl ?? "nil")")
        print("[Profile]    website_url: \(websiteUrl ?? "nil")")
        print("[Profile]    share_email: \(shareEmail.map { String($0) } ?? "nil")")
        print("[Profile]    share_phone: \(sharePhone.map { String($0) } ?? "nil")")
        print("[Profile]    preferred_contact_method: \(preferredContactMethod ?? "nil")")

        let payload = ProfileUpdatePayload(
            name: name,
            bio: bio,
            avatar_url: avatarUrl,
            includeAvatarUrl: avatarUrl != nil || clearAvatar,
            skills: skills,
            interests: interests,
            public_email: publicEmail,
            public_phone: publicPhone,
            linkedin_url: linkedInUrl,
            website_url: websiteUrl,
            share_email: shareEmail,
            share_phone: sharePhone,
            preferred_contact_method: preferredContactMethod
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
            skills: profile.skills,
            interests: profile.interests,
            imageUrl: profile.avatar_url,
            imagePath: nil,
            profileCompleted: true,
            connectionCount: nil,
            createdAt: nil,
            updatedAt: nil,
            publicEmail: profile.public_email,
            publicPhone: profile.public_phone,
            linkedInUrl: profile.linkedin_url,
            websiteUrl: profile.website_url,
            shareEmail: profile.share_email,
            sharePhone: profile.share_phone,
            preferredContactMethod: profile.preferred_contact_method
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
    let skills: [String]?
    let interests: [String]?
    let public_email: String?
    let public_phone: String?
    let linkedin_url: String?
    let website_url: String?
    let share_email: Bool?
    let share_phone: Bool?
    let preferred_contact_method: String?

    /// Only encodes avatar_url when explicitly requested (upload or clear).
    /// Prevents name/bio-only edits from accidentally nulling the avatar.
    /// Skills and interests are always included when non-nil.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(bio, forKey: .bio)
        if includeAvatarUrl {
            try container.encode(avatar_url, forKey: .avatar_url)
        }
        try container.encodeIfPresent(skills, forKey: .skills)
        try container.encodeIfPresent(interests, forKey: .interests)
        try container.encodeIfPresent(public_email, forKey: .public_email)
        try container.encodeIfPresent(public_phone, forKey: .public_phone)
        try container.encodeIfPresent(linkedin_url, forKey: .linkedin_url)
        try container.encodeIfPresent(website_url, forKey: .website_url)
        try container.encodeIfPresent(share_email, forKey: .share_email)
        try container.encodeIfPresent(share_phone, forKey: .share_phone)
        try container.encodeIfPresent(preferred_contact_method, forKey: .preferred_contact_method)
    }

    private enum CodingKeys: String, CodingKey {
        case name, bio, avatar_url, skills, interests
        case public_email, public_phone, linkedin_url, website_url
        case share_email, share_phone, preferred_contact_method
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
    let skills: [String]?
    let interests: [String]?
    let public_email: String?
    let public_phone: String?
    let linkedin_url: String?
    let website_url: String?
    let share_email: Bool?
    let share_phone: Bool?
    let preferred_contact_method: String?
}

struct ResolvedProfileResult {
    let authUser: Supabase.User
    let profile: User
    let state: ProfileState
}
