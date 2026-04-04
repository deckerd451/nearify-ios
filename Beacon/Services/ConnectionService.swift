// MARK: - Verification checklist
//
// After any future edit, confirm:
//   1. Xcode Shift+Cmd+F → "from_user_id" in connections context → 0 results
//   2. Xcode Shift+Cmd+F → "to_user_id" in connections context   → 0 results
//   3. Shift+Cmd+K (clean build folder), then Cmd+R
//   4. Tap Network tab — no PGRST200 in console
//   5. Console shows the ✅ debug lines below

import Foundation
import Supabase

final class ConnectionService {
    static let shared = ConnectionService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - createConnection

    /// Inserts an accepted connection from the current user to `profileId`.
    /// Columns written: requester_profile_id, addressee_profile_id, event_id, status.
    /// All IDs are profiles.id — never auth.users.id.
    func createConnection(to profileId: String) async throws {
        guard let currentUser = AuthService.shared.currentUser else {
            throw ConnectionError.notAuthenticated
        }
        guard let toId = UUID(uuidString: profileId) else {
            throw ConnectionError.invalidQRCode
        }

        // Resolve event_id if user is currently in an event
        let eventId: String? = await MainActor.run {
            EventJoinService.shared.currentEventID
        }

        print("[Connection] Creating connection:")
        print("[Connection]   requester_profile_id = \(currentUser.id) (profiles.id)")
        print("[Connection]   addressee_profile_id = \(toId) (profiles.id)")
        print("[Connection]   event_id             = \(eventId ?? "nil")")
        print("[Connection]   status               = accepted")

        struct Payload: Encodable {
            let requesterProfileId: UUID
            let addresseeProfileId: UUID
            let eventId: String?
            let status: String
            enum CodingKeys: String, CodingKey {
                case requesterProfileId = "requester_profile_id"
                case addresseeProfileId = "addressee_profile_id"
                case eventId            = "event_id"
                case status
            }
        }

        do {
            try await supabase
                .from("connections")
                .insert(Payload(
                    requesterProfileId: currentUser.id,
                    addresseeProfileId: toId,
                    eventId: eventId,
                    status: "accepted"
                ))
                .execute()

            print("[Connection] ✅ Connection inserted successfully")
        } catch {
            print("[Connection] ❌ Connection insert failed: \(error)")
            print("[Connection]   full error: \(String(describing: error))")
            throw error
        }
    }

    // MARK: - createConnectionIfNeeded

    enum ConnectResult {
        case created
        case alreadyExists
    }

    /// Creates a connection if one doesn't already exist. Returns the outcome.
    func createConnectionIfNeeded(to profileId: String) async throws -> ConnectResult {
        guard let currentUser = AuthService.shared.currentUser else {
            throw ConnectionError.notAuthenticated
        }
        guard let toId = UUID(uuidString: profileId) else {
            throw ConnectionError.invalidQRCode
        }

        let myId = currentUser.id.uuidString
        let targetId = toId.uuidString

        // Check both directions using the real column names
        let orFilter = "and(requester_profile_id.eq.\(myId),addressee_profile_id.eq.\(targetId)),and(requester_profile_id.eq.\(targetId),addressee_profile_id.eq.\(myId))"

        print("[Connection] Checking existing connection:")
        print("[Connection]   myId     = \(myId)")
        print("[Connection]   targetId = \(targetId)")

        struct Row: Decodable { let id: UUID }
        let existing: [Row] = try await supabase
            .from("connections")
            .select("id")
            .or(orFilter)
            .limit(1)
            .execute()
            .value

        if !existing.isEmpty {
            print("[Connection] ℹ️ Connection already exists (id: \(existing[0].id))")
            return .alreadyExists
        }

        try await createConnection(to: profileId)
        return .created
    }

    // MARK: - fetchConnections

    /// Fetches every accepted connection where the current user is on either side,
    /// with both profiles embedded via explicit FK constraint names.
    func fetchConnections() async throws -> [Connection] {
        guard let currentUser = AuthService.shared.currentUser else {
            return []
        }

        let myId = currentUser.id.uuidString

        let selectClause = """
            id,
            requester_profile_id,
            addressee_profile_id,
            event_id,
            status,
            created_at,
            updated_at,
            requester_profile:profiles!connections_requester_profile_id_fkey(id, name),
            addressee_profile:profiles!connections_addressee_profile_id_fkey(id, name)
            """

        let orFilter = "requester_profile_id.eq.\(myId),addressee_profile_id.eq.\(myId)"

        print("[Connection] fetchConnections running")
        print("[Connection]   myId: \(myId)")

        return try await supabase
            .from("connections")
            .select(selectClause)
            .or(orFilter)
            .eq("status", value: "accepted")
            .execute()
            .value
    }
}

// MARK: - ConnectionError

enum ConnectionError: Error {
    case notAuthenticated
    case invalidQRCode
}
