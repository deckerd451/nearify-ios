import Foundation

// MARK: - Conversation

/// Decoded row from the `conversations` table.
struct Conversation: Codable, Identifiable {
    let id: UUID
    let createdAt: Date?
    let participantA: UUID
    let participantB: UUID
    let eventId: UUID?
    let eventName: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case createdAt    = "created_at"
        case participantA = "participant_a"
        case participantB = "participant_b"
        case eventId      = "event_id"
        case eventName    = "event_name"
    }
    
    func otherParticipant(for myId: UUID) -> UUID {
        participantA == myId ? participantB : participantA
    }
}

// MARK: - Message

/// Decoded row from the `messages` table.
struct Message: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let senderProfileId: UUID
    let content: String
    let createdAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case conversationId   = "conversation_id"
        case senderProfileId  = "sender_profile_id"
        case content
        case createdAt        = "created_at"
    }
    
    func isMine(myId: UUID) -> Bool {
        senderProfileId == myId
    }
}
