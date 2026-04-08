import Foundation
import Supabase

/// Generates suggested connections from co-attendance at events.
/// Uses `profiles` as the canonical identity table and `connections`
/// for existing relationship exclusion.
final class SuggestedConnectionsService {
    static let shared = SuggestedConnectionsService()

    private let supabase = AppEnvironment.shared.supabaseClient

    /// Locally ignored profile IDs (session-only, not persisted)
    private var ignoredProfileIds: Set<UUID> = []

    private init() {}

    // MARK: - Nested Types

    /// Internal scoring model for ranking candidates.
    private struct CandidateScore {
        let profileId: UUID
        var sharedEventCount: Int = 0
        var lastSeenAt: Date = .distantPast
        // TODO: Add encounter-based scoring when EncounterService data is available
        // var overlapSeconds: Int = 0
        // var encounterConfidence: Double = 0.0

        var score: Double {
            // Simple scoring: shared events weighted heavily, recency as tiebreaker
            let eventScore = Double(sharedEventCount) * 10.0
            let recencyScore = max(0, 1.0 - (Date().timeIntervalSince(lastSeenAt) / 86400.0))
            return eventScore + recencyScore
        }
    }

    /// Row shape for co-attendee queries against event_attendees.
    private struct CoAttendeeRow: Decodable {
        let profileId: UUID
        let eventId: UUID
        let lastSeenAt: Date?

        enum CodingKeys: String, CodingKey {
            case profileId  = "profile_id"
            case eventId    = "event_id"
            case lastSeenAt = "last_seen_at"
        }
    }

    /// Minimal profile row for display name resolution.
    private struct ProfileNameRow: Decodable {
        let id: UUID
        let name: String?
    }

    // MARK: - Public API

    /// Resolves the current authenticated user's profile ID from `profiles`.
    /// Called by SuggestedConnectionsView on appear.
    func resolveCurrentUserProfileId() async throws -> UUID {
        let session = try await supabase.auth.session
        let authUserId = session.user.id

        struct Row: Decodable { let id: UUID }

        let rows: [Row] = try await supabase
            .from("profiles")
            .select("id")
            .eq("user_id", value: authUserId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else {
            throw NSError(domain: "SuggestedConnections", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No profile found for current user"])
        }

        return row.id
    }

    // Keep the old name as an alias so SuggestedConnectionsView compiles
    // without changes. Forwards to the correctly-named method.
    func resolveCurrentUserCommunityId() async throws -> UUID {
        try await resolveCurrentUserProfileId()
    }

    /// Generates suggestion candidates from co-attendance data.
    /// Returns the number of new candidates found.
    func generateSuggestions(
        groupId: UUID?,
        minOverlapSeconds: Int = 120,
        lookbackMinutes: Int = 240
    ) async throws -> Int {
        let currentProfileId = try await resolveCurrentUserProfileId()

        #if DEBUG
        print("[Suggestions] 🔍 Generating suggestions for profile: \(currentProfileId)")
        #endif

        // 1. Get existing connections to exclude
        let existingConnectionIds = try await fetchExistingConnectionProfileIds(for: currentProfileId)

        #if DEBUG
        print("[Suggestions]    Existing connections to exclude: \(existingConnectionIds.count)")
        #endif

        // 2. Find co-attendees from event_attendees
        let cutoff = Date().addingTimeInterval(-Double(lookbackMinutes) * 60)
        let cutoffISO = ISO8601DateFormatter().string(from: cutoff)

        // Fetch events the current user attended
        struct EventRow: Decodable { let eventId: UUID; enum CodingKeys: String, CodingKey { case eventId = "event_id" } }

        let myEvents: [EventRow] = try await supabase
            .from("event_attendees")
            .select("event_id")
            .eq("profile_id", value: currentProfileId.uuidString)
            .gte("last_seen_at", value: cutoffISO)
            .execute()
            .value

        let myEventIds = Set(myEvents.map { $0.eventId })

        guard !myEventIds.isEmpty else {
            #if DEBUG
            print("[Suggestions]    No recent events found")
            #endif
            return 0
        }

        // Fetch other attendees at those events
        let eventIdStrings = myEventIds.map { $0.uuidString }

        let coAttendees: [CoAttendeeRow] = try await supabase
            .from("event_attendees")
            .select("profile_id,event_id,last_seen_at")
            .in("event_id", values: eventIdStrings)
            .neq("profile_id", value: currentProfileId.uuidString)
            .execute()
            .value

        // 3. Score candidates
        var scores: [UUID: CandidateScore] = [:]

        for row in coAttendees {
            let pid = row.profileId

            // Skip already connected, self, or ignored
            guard !existingConnectionIds.contains(pid),
                  !ignoredProfileIds.contains(pid),
                  pid != currentProfileId else { continue }

            var candidate = scores[pid] ?? CandidateScore(profileId: pid)
            candidate.sharedEventCount += 1
            if let seen = row.lastSeenAt, seen > candidate.lastSeenAt {
                candidate.lastSeenAt = seen
            }
            scores[pid] = candidate
        }

        // TODO: Enrich scores with encounter data when available
        // let encounters = try await EncounterService.shared.fetchEncounters(for: currentProfileId)
        // for encounter in encounters { ... boost score ... }

        #if DEBUG
        print("[Suggestions]    Candidates found: \(scores.count)")
        #endif

        return scores.count
    }

    /// Fetches ranked suggestions for display.
    func fetchSuggestions(for profileId: UUID) async throws -> [SuggestedConnection] {
        let existingConnectionIds = try await fetchExistingConnectionProfileIds(for: profileId)

        // Re-run the co-attendee query to build scored results
        let cutoff = Date().addingTimeInterval(-240 * 60) // 4 hour lookback
        let cutoffISO = ISO8601DateFormatter().string(from: cutoff)

        struct EventRow: Decodable { let eventId: UUID; enum CodingKeys: String, CodingKey { case eventId = "event_id" } }

        let myEvents: [EventRow] = try await supabase
            .from("event_attendees")
            .select("event_id")
            .eq("profile_id", value: profileId.uuidString)
            .gte("last_seen_at", value: cutoffISO)
            .execute()
            .value

        let myEventIds = Set(myEvents.map { $0.eventId })
        guard !myEventIds.isEmpty else { return [] }

        let eventIdStrings = myEventIds.map { $0.uuidString }

        let coAttendees: [CoAttendeeRow] = try await supabase
            .from("event_attendees")
            .select("profile_id,event_id,last_seen_at")
            .in("event_id", values: eventIdStrings)
            .neq("profile_id", value: profileId.uuidString)
            .execute()
            .value

        // Score
        var scores: [UUID: CandidateScore] = [:]
        for row in coAttendees {
            let pid = row.profileId
            guard !existingConnectionIds.contains(pid),
                  !ignoredProfileIds.contains(pid),
                  pid != profileId else { continue }

            var candidate = scores[pid] ?? CandidateScore(profileId: pid)
            candidate.sharedEventCount += 1
            if let seen = row.lastSeenAt, seen > candidate.lastSeenAt {
                candidate.lastSeenAt = seen
            }
            scores[pid] = candidate
        }

        // Resolve display names
        let candidateIds = Array(scores.keys)
        guard !candidateIds.isEmpty else { return [] }

        let profiles: [ProfileNameRow] = try await supabase
            .from("profiles")
            .select("id,name")
            .in("id", values: candidateIds.map { $0.uuidString })
            .execute()
            .value

        let nameMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name ?? "Unknown") })

        // Build sorted results
        let ranked = scores.values
            .sorted { $0.score > $1.score }
            .prefix(20)

        return ranked.map { candidate in
            SuggestedConnection(
                id: candidate.profileId,
                otherUserId: candidate.profileId,
                displayName: nameMap[candidate.profileId] ?? "Unknown",
                sharedEvents: candidate.sharedEventCount,
                lastSeenAt: candidate.lastSeenAt
            )
        }
    }

    /// Creates a connection to the suggested profile.
    func acceptSuggestion(profileId: UUID) async throws {
        try await ConnectionService.shared.createConnection(to: profileId.uuidString)
    }

    /// Locally ignores a suggestion for this session.
    func ignoreSuggestion(profileId: UUID) {
        ignoredProfileIds.insert(profileId)
    }

    // MARK: - Private Helpers

    /// Fetches all profile IDs the user is already connected with (any status that
    /// should exclude them from suggestions). Checks both directions of the connection.
    private func fetchExistingConnectionProfileIds(for profileId: UUID) async throws -> Set<UUID> {
        let myId = profileId.uuidString

        struct ConnectionRow: Decodable {
            let requesterProfileId: UUID
            let addresseeProfileId: UUID

            enum CodingKeys: String, CodingKey {
                case requesterProfileId = "requester_profile_id"
                case addresseeProfileId = "addressee_profile_id"
            }
        }

        // Fetch connections where user is on either side.
        // Include both 'accepted' and 'pending' to avoid re-suggesting.
        let rows: [ConnectionRow] = try await supabase
            .from("connections")
            .select("requester_profile_id,addressee_profile_id")
            .or("requester_profile_id.eq.\(myId),addressee_profile_id.eq.\(myId)")
            .in("status", values: ["accepted", "pending"])
            .execute()
            .value

        var ids = Set<UUID>()
        for row in rows {
            if row.requesterProfileId == profileId {
                ids.insert(row.addresseeProfileId)
            } else {
                ids.insert(row.requesterProfileId)
            }
        }

        return ids
    }
}
