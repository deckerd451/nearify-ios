import Foundation
import Supabase

final class SuggestedConnectionsService {
    static let shared = SuggestedConnectionsService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Generate Suggestions (client-side, no RPC)

    /// Generates suggestions by finding other attendees at the same event(s)
    /// the current user attended. Excludes existing connections.
    /// Returns the count of new suggestions found.
    func generateSuggestions(
        groupId: UUID?,
        minOverlapSeconds: Int = 120,
        lookbackMinutes: Int = 240
    ) async throws -> Int {
        guard let currentProfileId = try? await resolveCurrentUserCommunityId() else {
            throw NSError(domain: "SuggestedConnections", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Could not resolve current user profile"])
        }

        print("[Suggestions] 🔍 Generating suggestions for profile: \(currentProfileId)")

        // 1. Find events the current user has attended
        let myAttendance: [AttendanceRow] = try await supabase
            .from("event_attendees")
            .select("event_id, profile_id, last_seen_at")
            .eq("profile_id", value: currentProfileId.uuidString)
            .eq("status", value: "joined")
            .execute()
            .value

        let eventIds = Array(Set(myAttendance.map(\.eventId)))
        print("[Suggestions]    Events attended: \(eventIds.count)")

        guard !eventIds.isEmpty else {
            print("[Suggestions]    No events found — no suggestions possible")
            return 0
        }

        // 2. Find all other attendees at those events
        let eventFilters = eventIds.map { "event_id.eq.\($0.uuidString)" }.joined(separator: ",")

        let coAttendees: [AttendanceRow] = try await supabase
            .from("event_attendees")
            .select("event_id, profile_id, last_seen_at")
            .or(eventFilters)
            .eq("status", value: "joined")
            .neq("profile_id", value: currentProfileId.uuidString)
            .execute()
            .value

        // Deduplicate by profile_id, keeping the most recent last_seen_at
        var bestByProfile: [UUID: AttendanceRow] = [:]
        for row in coAttendees {
            if let existing = bestByProfile[row.profileId] {
                if row.lastSeenAt > existing.lastSeenAt {
                    bestByProfile[row.profileId] = row
                }
            } else {
                bestByProfile[row.profileId] = row
            }
        }

        print("[Suggestions]    Co-attendees found: \(bestByProfile.count)")

        guard !bestByProfile.isEmpty else {
            print("[Suggestions]    No co-attendees — no suggestions possible")
            return 0
        }

        // 3. Exclude existing connections
        let existingConnectionIds = try await fetchExistingConnectionProfileIds(for: currentProfileId)
        print("[Suggestions]    Existing connections: \(existingConnectionIds.count)")

        let candidateIds = bestByProfile.keys.filter { !existingConnectionIds.contains($0) }
        print("[Suggestions]    Candidates after filtering: \(candidateIds.count)")

        guard !candidateIds.isEmpty else {
            print("[Suggestions]    All co-attendees are already connected")
            return 0
        }

        // 4. Build event overlap counts per candidate (how many shared events)
        var sharedEventCount: [UUID: Int] = [:]
        let myEventSet = Set(eventIds)
        for row in coAttendees {
            guard candidateIds.contains(row.profileId), myEventSet.contains(row.eventId) else { continue }
            sharedEventCount[row.profileId, default: 0] += 1
        }

        // Store suggestions in memory for fetchSuggestions to return
        _generatedSuggestions = candidateIds.map { profileId in
            GeneratedSuggestion(
                profileId: profileId,
                sharedEvents: sharedEventCount[profileId] ?? 1,
                lastSeenAt: bestByProfile[profileId]?.lastSeenAt ?? Date()
            )
        }
        .sorted { $0.sharedEvents > $1.sharedEvents }

        print("[Suggestions] ✅ Generated \(_generatedSuggestions.count) suggestions")
        return _generatedSuggestions.count
    }

    // MARK: - In-memory suggestion store

    private var _generatedSuggestions: [GeneratedSuggestion] = []

    // MARK: - Fetch Suggestions

    /// Returns suggestions with profile names resolved.
    func fetchSuggestions(for profileId: UUID) async throws -> [SuggestedConnection] {
        guard !_generatedSuggestions.isEmpty else {
            print("[Suggestions] ℹ️ No generated suggestions to display")
            return []
        }

        let profileIds = _generatedSuggestions.map(\.profileId)
        let names = await fetchUserProfiles(for: profileIds)

        return _generatedSuggestions.map { suggestion in
            let name = names[suggestion.profileId] ?? "User \(suggestion.profileId.uuidString.prefix(8))"
            return SuggestedConnection(
                id: suggestion.profileId,
                otherUserId: suggestion.profileId,
                displayName: name,
                sharedEvents: suggestion.sharedEvents,
                lastSeenAt: suggestion.lastSeenAt
            )
        }
    }

    // MARK: - Actions

    /// Accept a suggestion — creates a connection
    func acceptSuggestion(profileId: UUID) async throws {
        try await ConnectionService.shared.createConnection(to: profileId.uuidString)
        _generatedSuggestions.removeAll { $0.profileId == profileId }
        print("[Suggestions] ✅ Accepted suggestion → connection created for \(profileId)")
    }

    /// Ignore a suggestion — just remove from local list
    func ignoreSuggestion(profileId: UUID) {
        _generatedSuggestions.removeAll { $0.profileId == profileId }
        print("[Suggestions] ✅ Ignored suggestion for \(profileId)")
    }

    // MARK: - Helpers

    private func fetchExistingConnectionProfileIds(for profileId: UUID) async throws -> Set<UUID> {
        let connections = try await ConnectionService.shared.fetchConnections()
        var ids = Set<UUID>()
        for conn in connections {
            if conn.requesterProfileId == profileId {
                ids.insert(conn.addresseeProfileId)
            } else {
                ids.insert(conn.requesterProfileId)
            }
        }
        return ids
    }

    private func fetchUserProfiles(for userIds: [UUID]) async -> [UUID: String] {
        guard !userIds.isEmpty else { return [:] }

        do {
            let cappedIds = Array(userIds.prefix(50))
            let filters = cappedIds.map { "id.eq.\($0.uuidString)" }.joined(separator: ",")

            let response: [CommunityProfile] = try await supabase
                .from("profiles")
                .select("id, name")
                .or(filters)
                .execute()
                .value

            return Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0.name) })
        } catch {
            print("[Suggestions] ⚠️ Failed to fetch profiles: \(error)")
            return [:]
        }
    }

    /// Resolve current user's profiles.id from auth session
    func resolveCurrentUserCommunityId() async throws -> UUID {
        let session = try await supabase.auth.session
        let authUserId = session.user.id

        let response: [CommunityProfile] = try await supabase
            .from("profiles")
            .select("id, name")
            .eq("user_id", value: authUserId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let profile = response.first else {
            throw NSError(domain: "SuggestedConnections", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Could not resolve profiles.id for current user"])
        }

        print("[Suggestions] ✅ Resolved profiles.id: \(profile.id)")
        return profile.id
    }
}

// MARK: - Internal Models

private struct AttendanceRow: Codable {
    let eventId: UUID
    let profileId: UUID
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case profileId = "profile_id"
        case lastSeenAt = "last_seen_at"
    }
}

private struct GeneratedSuggestion {
    let profileId: UUID
    let sharedEvents: Int
    let lastSeenAt: Date
}
