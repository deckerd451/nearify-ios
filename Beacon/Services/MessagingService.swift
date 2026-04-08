import Foundation
import Combine
import Supabase

/// Lightweight messaging between connected users.
/// Only enabled after QR-confirmed or accepted connection.
/// All profile IDs reference profiles.id (community identity).
@MainActor
final class MessagingService: ObservableObject {
    
    static let shared = MessagingService()
    
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentMessages: [Message] = []
    @Published private(set) var isLoading = false
    
    private let supabase = AppEnvironment.shared.supabaseClient
    
    private init() {}
    
    // MARK: - Conversations
    
    /// Fetches all conversations for the current user.
    func fetchConversations() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let convos: [Conversation] = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .order("created_at", ascending: false)
                .execute()
                .value
            
            conversations = convos
            
            #if DEBUG
            print("[Messaging] ✅ Loaded \(convos.count) conversations")
            #endif
        } catch {
            print("[Messaging] ❌ Failed to fetch conversations: \(error)")
        }
    }
    
    // MARK: - Messages
    
    /// Fetches messages for a specific conversation.
    func fetchMessages(conversationId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let msgs: [Message] = try await supabase
                .from("messages")
                .select("*")
                .eq("conversation_id", value: conversationId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            
            currentMessages = msgs
            
            #if DEBUG
            print("[Messaging] ✅ Loaded \(msgs.count) messages for conversation \(conversationId)")
            #endif
        } catch {
            print("[Messaging] ❌ Failed to fetch messages: \(error)")
        }
    }
    
    // MARK: - Send Message
    
    /// Sends a text message in an existing conversation.
    func sendMessage(conversationId: UUID, content: String) async throws {
        guard let myId = AuthService.shared.currentUser?.id else {
            throw MessagingError.notAuthenticated
        }
        
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessagingError.emptyMessage }
        
        let payload = MessageInsertPayload(
            conversationId: conversationId,
            senderProfileId: myId,
            content: trimmed
        )
        
        try await supabase
            .from("messages")
            .insert(payload)
            .execute()
        
        // Refresh messages after send
        await fetchMessages(conversationId: conversationId)
        
        #if DEBUG
        print("[Messaging] ✅ Sent message in conversation \(conversationId)")
        #endif
    }
    
    // MARK: - Get or Create Conversation
    
    /// Finds an existing conversation with the target user, or creates one.
    /// Only works if a connection exists between the two users.
    func getOrCreateConversation(with targetProfileId: UUID, eventId: UUID? = nil, eventName: String? = nil) async throws -> Conversation {
        guard let myId = AuthService.shared.currentUser?.id else {
            throw MessagingError.notAuthenticated
        }
        
        // Verify connection exists before allowing conversation
        let connected = await ConnectionService.shared.isConnected(with: targetProfileId)
        guard connected else {
            #if DEBUG
            print("[Messaging] ⛔ Cannot create conversation — not connected with \(targetProfileId)")
            #endif
            throw MessagingError.notConnected
        }
        
        // Check for existing conversation
        let existing: [Conversation] = try await supabase
            .from("conversations")
            .select("*")
            .or("and(participant_a.eq.\(myId.uuidString),participant_b.eq.\(targetProfileId.uuidString)),and(participant_a.eq.\(targetProfileId.uuidString),participant_b.eq.\(myId.uuidString))")
            .limit(1)
            .execute()
            .value
        
        if let convo = existing.first {
            return convo
        }
        
        // Create new conversation
        let payload = ConversationInsertPayload(
            participantA: myId,
            participantB: targetProfileId,
            eventId: eventId,
            eventName: eventName
        )
        
        let created: Conversation = try await supabase
            .from("conversations")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
        
        #if DEBUG
        print("[Messaging] ✅ Created conversation \(created.id) with \(targetProfileId)")
        #endif
        
        return created
    }
}

// MARK: - Errors

enum MessagingError: Error, LocalizedError {
    case notAuthenticated
    case emptyMessage
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .emptyMessage: return "Message cannot be empty"
        case .notConnected: return "You must be connected to message this person"
        }
    }
}

// MARK: - Payloads

private struct MessageInsertPayload: Encodable {
    let conversationId: UUID
    let senderProfileId: UUID
    let content: String
    
    enum CodingKeys: String, CodingKey {
        case conversationId   = "conversation_id"
        case senderProfileId  = "sender_profile_id"
        case content
    }
}

private struct ConversationInsertPayload: Encodable {
    let participantA: UUID
    let participantB: UUID
    let eventId: UUID?
    let eventName: String?
    
    enum CodingKeys: String, CodingKey {
        case participantA = "participant_a"
        case participantB = "participant_b"
        case eventId      = "event_id"
        case eventName    = "event_name"
    }
}
