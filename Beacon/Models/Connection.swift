import Foundation

// MARK: - CommunityProfile

/// Lightweight profile row decoded from PostgREST FK embeds on the `community` table.
/// Used by community-table queries.
struct CommunityProfile: Codable {
    let id: UUID
    let name: String
}

// MARK: - ConnectionProfile

/// One embedded profile row, decoded from a PostgREST FK embed on `profiles`.
/// Columns selected: id, name
struct ConnectionProfile: Codable {
    let id: UUID
    let name: String
}

// MARK: - Connection

/// Decoded row from the `connections` table.
///
/// Real schema:
///   id (uuid), requester_profile_id (uuid), addressee_profile_id (uuid),
///   event_id (uuid, nullable), status (text),
///   created_at (timestamp), updated_at (timestamp)
///
/// FK constraints used for PostgREST embedding:
///   connections_requester_profile_id_fkey  (requester_profile_id → profiles.id)
///   connections_addressee_profile_id_fkey  (addressee_profile_id → profiles.id)
struct Connection: Codable, Identifiable {
    let id: UUID
    let requesterProfileId: UUID
    let addresseeProfileId: UUID
    let eventId: UUID?
    let status: String?
    let createdAt: Date?
    let updatedAt: Date?
    let requesterProfile: ConnectionProfile?
    let addresseeProfile: ConnectionProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterProfileId = "requester_profile_id"
        case addresseeProfileId = "addressee_profile_id"
        case eventId            = "event_id"
        case status
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
        case requesterProfile   = "requester_profile"
        case addresseeProfile   = "addressee_profile"
    }

    /// Returns the id and name of whichever user is NOT the current user.
    func otherUser(for currentProfileId: UUID) -> (id: UUID, name: String) {
        if requesterProfileId == currentProfileId {
            return (id: addresseeProfile?.id ?? addresseeProfileId,
                    name: addresseeProfile?.name ?? "Unknown")
        } else {
            return (id: requesterProfile?.id ?? requesterProfileId,
                    name: requesterProfile?.name ?? "Unknown")
        }
    }
}
