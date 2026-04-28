import Foundation

struct ContactShareRequest: Decodable, Identifiable, Equatable {
    let id: UUID
    let requesterProfileId: UUID
    let addresseeProfileId: UUID
    let eventId: UUID?
    let status: String
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterProfileId = "requester_profile_id"
        case addresseeProfileId = "addressee_profile_id"
        case eventId = "event_id"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
