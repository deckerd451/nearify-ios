import Foundation

/// Lightweight in-memory profile cache for offline fallback.
/// Populated automatically when profiles are fetched during online operation.
/// Used to resolve BLE-detected people when backend is unavailable.
@MainActor
final class ProfileCache {

    static let shared = ProfileCache()

    struct CachedProfile {
        let id: UUID
        let name: String
        let avatarUrl: String?
    }

    private var cache: [UUID: CachedProfile] = [:]

    private init() {}

    // MARK: - Write (called during online operation)

    /// Cache a profile. Called by services when they fetch profile data.
    func store(id: UUID, name: String, avatarUrl: String?) {
        cache[id] = CachedProfile(id: id, name: name, avatarUrl: avatarUrl)
    }

    /// Cache profiles from the attendee list.
    func storeAttendees(_ attendees: [EventAttendee]) {
        for a in attendees {
            cache[a.id] = CachedProfile(id: a.id, name: a.name, avatarUrl: a.avatarUrl)
        }
    }

    /// Cache profiles from relationship memory.
    func storeRelationships(_ relationships: [RelationshipMemory]) {
        for r in relationships {
            cache[r.profileId] = CachedProfile(
                id: r.profileId, name: r.name, avatarUrl: r.avatarUrl
            )
        }
    }

    // MARK: - Read (used during offline fallback)

    /// Look up a cached profile by ID.
    func profile(for id: UUID) -> CachedProfile? {
        cache[id]
    }

    /// Look up a cached profile by BLE prefix (first 8 chars of UUID).
    func profile(forPrefix prefix: String) -> CachedProfile? {
        cache.values.first { p in
            String(p.id.uuidString.prefix(8)).lowercased() == prefix
        }
    }

    /// Build a stable display name for a BLE prefix.
    /// Priority: cached name → derived initials → stable anonymous identity.
    func displayName(forPrefix prefix: String) -> String {
        if let cached = profile(forPrefix: prefix) {
            return cached.name
        }
        // Stable anonymous identity derived from prefix (not random)
        return "Nearby \(prefix.prefix(4).uppercased())"
    }

    /// Build a minimal EventAttendee from cache + BLE prefix for offline Find.
    func offlineAttendee(forPrefix prefix: String, profileId: UUID) -> EventAttendee {
        let cached = profile(for: profileId) ?? profile(forPrefix: prefix)
        return EventAttendee(
            id: profileId,
            name: cached?.name ?? displayName(forPrefix: prefix),
            avatarUrl: cached?.avatarUrl,
            bio: nil,
            skills: nil,
            interests: nil,
            energy: 0.5,
            lastSeen: Date()
        )
    }

    var count: Int { cache.count }
}
