import Foundation

/// Lightweight UserDefaults-backed cache for the last known authenticated user profile.
/// Written after every successful online profile load.
/// Read during offline cold launch to provide a usable identity without network.
///
/// Stores the minimum fields needed to enter the app in offline mode:
/// profileId, authUserId, name, email, avatarUrl, lastEventId, lastEventName, timestamp.
@MainActor
final class CachedIdentityStore {

    static let shared = CachedIdentityStore()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let profileId       = "cachedIdentity.profileId"
        static let authUserId      = "cachedIdentity.authUserId"
        static let name            = "cachedIdentity.name"
        static let email           = "cachedIdentity.email"
        static let avatarUrl       = "cachedIdentity.avatarUrl"
        static let bio             = "cachedIdentity.bio"
        static let skills          = "cachedIdentity.skills"
        static let interests       = "cachedIdentity.interests"
        static let lastEventId     = "cachedIdentity.lastEventId"
        static let lastEventName   = "cachedIdentity.lastEventName"
        static let cachedAt        = "cachedIdentity.cachedAt"
    }

    private init() {}

    // MARK: - Write (called after successful online profile load)

    /// Persists the current user profile to disk.
    /// Call this immediately after a confirmed valid profile load from public.profiles.
    func store(user: User, authUserId: UUID? = nil) {
        defaults.set(user.id.uuidString, forKey: Key.profileId)
        defaults.set((authUserId ?? user.userId)?.uuidString, forKey: Key.authUserId)
        defaults.set(user.name, forKey: Key.name)
        defaults.set(user.email, forKey: Key.email)
        defaults.set(user.imageUrl, forKey: Key.avatarUrl)
        defaults.set(user.bio, forKey: Key.bio)

        if let skills = user.skills {
            defaults.set(skills, forKey: Key.skills)
        } else {
            defaults.removeObject(forKey: Key.skills)
        }

        if let interests = user.interests {
            defaults.set(interests, forKey: Key.interests)
        } else {
            defaults.removeObject(forKey: Key.interests)
        }

        defaults.set(Date().timeIntervalSince1970, forKey: Key.cachedAt)

        // Preserve last event context if available
        if let eventId = EventJoinService.shared.currentEventID {
            defaults.set(eventId, forKey: Key.lastEventId)
        }
        if let eventName = EventJoinService.shared.currentEventName {
            defaults.set(eventName, forKey: Key.lastEventName)
        }

        #if DEBUG
        print("[CachedIdentity] ✅ Stored: \(user.name) (id: \(user.id.uuidString.prefix(8)))")
        #endif
    }

    // MARK: - Read (used during offline cold launch)

    /// Returns true if a cached identity exists on disk.
    var hasCachedIdentity: Bool {
        defaults.string(forKey: Key.profileId) != nil
            && defaults.string(forKey: Key.name) != nil
    }

    /// Reconstructs a User from the cached identity.
    /// Returns nil if no valid cache exists.
    func loadCachedUser() -> User? {
        guard let profileIdStr = defaults.string(forKey: Key.profileId),
              let profileId = UUID(uuidString: profileIdStr),
              let name = defaults.string(forKey: Key.name) else {
            #if DEBUG
            print("[CachedIdentity] ℹ️ No cached identity available")
            #endif
            return nil
        }

        let authUserIdStr = defaults.string(forKey: Key.authUserId)
        let authUserId = authUserIdStr.flatMap { UUID(uuidString: $0) }

        let user = User(
            id: profileId,
            userId: authUserId,
            name: name,
            email: defaults.string(forKey: Key.email),
            bio: defaults.string(forKey: Key.bio),
            skills: defaults.stringArray(forKey: Key.skills),
            interests: defaults.stringArray(forKey: Key.interests),
            imageUrl: defaults.string(forKey: Key.avatarUrl),
            imagePath: nil,
            profileCompleted: true,
            connectionCount: nil,
            createdAt: nil,
            updatedAt: nil
        )

        #if DEBUG
        let age = cachedAge.map { "\(Int($0))s ago" } ?? "unknown"
        print("[CachedIdentity] ✅ Loaded: \(name) (id: \(profileId.uuidString.prefix(8)), cached \(age))")
        #endif

        return user
    }

    /// The last event ID from the cached identity, if available.
    var lastEventId: String? {
        defaults.string(forKey: Key.lastEventId)
    }

    /// The last event name from the cached identity, if available.
    var lastEventName: String? {
        defaults.string(forKey: Key.lastEventName)
    }

    /// How old the cached identity is, in seconds. Nil if no cache exists.
    var cachedAge: TimeInterval? {
        let ts = defaults.double(forKey: Key.cachedAt)
        guard ts > 0 else { return nil }
        return Date().timeIntervalSince1970 - ts
    }

    // MARK: - Clear (called on sign-out)

    func clear() {
        for key in [Key.profileId, Key.authUserId, Key.name, Key.email,
                    Key.avatarUrl, Key.bio, Key.skills, Key.interests,
                    Key.lastEventId, Key.lastEventName, Key.cachedAt] {
            defaults.removeObject(forKey: key)
        }

        #if DEBUG
        print("[CachedIdentity] 🗑️ Cache cleared")
        #endif
    }
}
