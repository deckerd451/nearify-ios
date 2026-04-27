// MARK: - Verification checklist
//
// After any future edit, confirm:
//   1. Xcode Shift+Cmd+F → "from_user_id" in connections context → 0 results
//   2. Xcode Shift+Cmd+F → "to_user_id" in connections context   → 0 results
//   3. Shift+Cmd+K (clean build folder), then Cmd+R
//   4. Tap Event tab — no PGRST200 in console
//   5. Console shows the ✅ debug lines below

import Foundation
import Supabase

final class ConnectionService {
    static let shared = ConnectionService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Types

    enum ConnectResult {
        case created
        case alreadyExists
    }

    enum EncounterConnectionState: Equatable {
        case none
        case outgoingPending
        case incomingPending
        case connected
    }

    enum ConnectionRequestResult {
        case created
        case alreadyPendingOutgoing
        case alreadyPendingIncoming
        case alreadyConnected
    }

    private struct CreatePayload: Encodable {
        let requesterProfileId: UUID
        let addresseeProfileId: UUID
        let eventId: String?
        let status: String

        enum CodingKeys: String, CodingKey {
            case requesterProfileId = "requester_profile_id"
            case addresseeProfileId = "addressee_profile_id"
            case eventId = "event_id"
            case status
        }
    }

    private struct ConnectionIdRow: Decodable {
        let id: UUID
    }

    private struct ConnectionStatusRow: Decodable {
        let id: UUID
        let requesterProfileId: UUID
        let addresseeProfileId: UUID
        let status: String?

        enum CodingKeys: String, CodingKey {
            case id
            case requesterProfileId = "requester_profile_id"
            case addresseeProfileId = "addressee_profile_id"
            case status
        }
    }

    // MARK: - Public API

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

        let eventId: String? = await MainActor.run {
            EventJoinService.shared.currentEventID
        }

        print("[Connection] Creating connection:")
        print("[Connection]   requester_profile_id = \(currentUser.id) (profiles.id)")
        print("[Connection]   addressee_profile_id = \(toId) (profiles.id)")
        print("[Connection]   event_id             = \(eventId ?? "nil")")
        print("[Connection]   status               = accepted")

        do {
            try await supabase
                .from("connections")
                .insert(
                    CreatePayload(
                        requesterProfileId: currentUser.id,
                        addresseeProfileId: toId,
                        eventId: eventId,
                        status: "accepted"
                    )
                )
                .execute()

            print("[Connection] ✅ Connection inserted successfully")

            // Resolve name for notification
            Task {
                let name = try? await ProfileService.shared.fetchProfileById(toId)
                await NotificationService.shared.onConnectionCreated(
                    profileId: toId,
                    profileName: name?.name
                )
                await FeedService.shared.requestRefresh(reason: "connection-created")
            }
        } catch {
            print("[Connection] ❌ Connection insert failed: \(error)")
            print("[Connection]   full error: \(String(describing: error))")
            throw error
        }
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
        let orFilter = bidirectionalFilter(myId: myId, targetId: targetId)

        print("[Connection] Checking existing connection:")
        print("[Connection]   myId     = \(myId)")
        print("[Connection]   targetId = \(targetId)")

        let existing: [ConnectionIdRow] = try await supabase
            .from("connections")
            .select("id")
            .or(orFilter)
            .limit(1)
            .execute()
            .value

        if let first = existing.first {
            print("[Connection] ℹ️ Connection already exists (id: \(first.id))")
            return .alreadyExists
        }

        try await createConnection(to: profileId)
        return .created
    }

    /// Creates a pending request from the current user to `profileId`.
    /// If an inverse pending request exists, this call auto-approves by accepting that row.
    func createConnectionRequest(to profileId: String) async throws -> ConnectionRequestResult {
        guard let currentUser = AuthService.shared.currentUser else {
            throw ConnectionError.notAuthenticated
        }

        guard let toId = UUID(uuidString: profileId) else {
            throw ConnectionError.invalidQRCode
        }

        let state = try await fetchEncounterConnectionState(with: toId)
        switch state {
        case .connected:
            return .alreadyConnected
        case .outgoingPending:
            return .alreadyPendingOutgoing
        case .incomingPending:
            try await approveConnectionRequest(with: toId)
            return .alreadyPendingIncoming
        case .none:
            break
        }

        let eventId: String? = await MainActor.run {
            EventJoinService.shared.currentEventID
        }

        try await supabase
            .from("connections")
            .insert(
                CreatePayload(
                    requesterProfileId: currentUser.id,
                    addresseeProfileId: toId,
                    eventId: eventId,
                    status: "pending"
                )
            )
            .execute()

        Task {
            await FeedService.shared.requestRefresh(reason: "connection-request-created")
        }
        return .created
    }

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

    /// Checks whether the current user has an accepted connection with the given profile.
    /// Checks both directions of the relationship.
    func isConnected(with profileId: UUID) async -> Bool {
        guard let currentUser = AuthService.shared.currentUser else {
            print("[Connection] ⚠️ isConnected check failed: no authenticated user")
            return false
        }

        let myId = currentUser.id.uuidString
        let targetId = profileId.uuidString
        let orFilter = bidirectionalFilter(myId: myId, targetId: targetId)

        let rows: [ConnectionIdRow]? = try? await supabase
            .from("connections")
            .select("id")
            .or(orFilter)
            .eq("status", value: "accepted")
            .limit(1)
            .execute()
            .value

        let isConnected = !(rows?.isEmpty ?? true)
        print("[Connection] isConnected(\(targetId)) → \(isConnected)")
        return isConnected
    }

    func fetchEncounterConnectionState(with profileId: UUID) async throws -> EncounterConnectionState {
        guard let currentUser = AuthService.shared.currentUser else {
            throw ConnectionError.notAuthenticated
        }

        let myId = currentUser.id.uuidString
        let targetId = profileId.uuidString
        let orFilter = bidirectionalFilter(myId: myId, targetId: targetId)

        let rows: [ConnectionStatusRow] = try await supabase
            .from("connections")
            .select("id,requester_profile_id,addressee_profile_id,status")
            .or(orFilter)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { return .none }
        let status = row.status?.lowercased() ?? ""

        if status == "accepted" {
            return .connected
        }

        if status == "pending" {
            if row.requesterProfileId == currentUser.id {
                return .outgoingPending
            } else {
                return .incomingPending
            }
        }

        return .none
    }

    func approveConnectionRequest(with profileId: UUID) async throws {
        guard let currentUser = AuthService.shared.currentUser else {
            throw ConnectionError.notAuthenticated
        }

        let currentId = currentUser.id.uuidString
        let requesterId = profileId.uuidString

        try await supabase
            .from("connections")
            .update(["status": "accepted"])
            .eq("requester_profile_id", value: requesterId)
            .eq("addressee_profile_id", value: currentId)
            .eq("status", value: "pending")
            .execute()

        Task {
            await NotificationService.shared.onConnectionCreated(
                profileId: profileId,
                profileName: nil
            )
            await FeedService.shared.requestRefresh(reason: "connection-request-approved")
            await AttendeeStateResolver.shared.refreshConnections()
        }
    }

    // MARK: - Helpers

    private func bidirectionalFilter(myId: String, targetId: String) -> String {
        "and(requester_profile_id.eq.\(myId),addressee_profile_id.eq.\(targetId)),and(requester_profile_id.eq.\(targetId),addressee_profile_id.eq.\(myId))"
    }
}

// MARK: - ConnectionError

enum ConnectionError: Error {
    case notAuthenticated
    case invalidQRCode
}
