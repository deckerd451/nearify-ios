import Foundation
import Combine
import Supabase
import UIKit
import UserNotifications

/// Lightweight messaging between connected users.
/// Only enabled after QR-confirmed or accepted connection.
/// All profile IDs reference profiles.id (community identity).
@MainActor
final class MessagingService: ObservableObject {

    static let shared = MessagingService()

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentMessages: [Message] = []
    @Published private(set) var unreadByConversation: [UUID: Int] = [:]
    @Published private(set) var totalUnreadCount: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isMessagesTabActive = false

    /// Conversation currently rendered in UI (used for live append + notification suppression).
    @Published var activeConversationId: UUID?
    @Published private(set) var visibleConversationIds: Set<UUID> = []

    private let supabase = AppEnvironment.shared.supabaseClient
    private var currentConversationId: UUID?
    private var profileNameCache: [UUID: String] = [:]
    private var conversationLoadTask: Task<[Conversation], Never>?
    private var pendingConversationReload = false
    private var processedIncomingMessageIds: Set<UUID> = []
    private var processedIncomingOrder: [UUID] = []
    private let maxProcessedIncomingIds = 2_000

    private init() {}

    // MARK: - Conversations

    /// Fetches all conversations for the current user.
    func fetchConversations() async {
        _ = await fetchConversationsSnapshot()
    }

    /// Returns a sorted snapshot and updates published conversations.
    func fetchConversationsSnapshot() async -> [Conversation] {
        if let inFlight = conversationLoadTask {
            pendingConversationReload = true
            return await inFlight.value
        }

        var latestResult: [Conversation] = []

        repeat {
            pendingConversationReload = false
            let task = Task<[Conversation], Never> { [weak self] in
                guard let self else { return [Conversation]() }
                return await self.performConversationSnapshotFetch()
            }
            conversationLoadTask = task
            latestResult = await task.value
            conversationLoadTask = nil
        } while pendingConversationReload

        return latestResult
    }

    private func performConversationSnapshotFetch() async -> [Conversation] {
        guard let myId = AuthService.shared.currentUser?.id else { return [] }

        isLoading = true
        defer { isLoading = false }

        do {
            let convos: [Conversation] = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .execute()
                .value

            let sorted = await sortConversationsByLatestMessage(convos)
            conversations = sorted

            #if DEBUG
            print("[Messaging] ✅ Loaded \(sorted.count) conversations")
            #endif
            return sorted
        } catch {
            print("[Messaging] ❌ Failed to fetch conversations: \(error)")
            return []
        }
    }

    private func sortConversationsByLatestMessage(_ convos: [Conversation]) async -> [Conversation] {
        guard !convos.isEmpty else { return convos }

        var latestByConversation: [UUID: Date] = [:]

        await withTaskGroup(of: (UUID, Date?).self) { group in
            for convo in convos {
                group.addTask { [supabase] in
                    struct LastMessageRow: Decodable {
                        let createdAt: Date
                        enum CodingKeys: String, CodingKey {
                            case createdAt = "created_at"
                        }
                    }

                    let latest: Date?
                    do {
                        let row: [LastMessageRow] = try await supabase
                            .from("messages")
                            .select("created_at")
                            .eq("conversation_id", value: convo.id.uuidString)
                            .order("created_at", ascending: false)
                            .limit(1)
                            .execute()
                            .value
                        latest = row.first?.createdAt
                    } catch {
                        latest = nil
                    }

                    return (convo.id, latest)
                }
            }

            for await (id, latest) in group {
                latestByConversation[id] = latest
            }
        }

        return convos.sorted { lhs, rhs in
            let l = latestByConversation[lhs.id] ?? lhs.createdAt ?? .distantPast
            let r = latestByConversation[rhs.id] ?? rhs.createdAt ?? .distantPast
            return l > r
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

            currentConversationId = conversationId
            currentMessages = msgs
            markConversationViewed(conversationId: conversationId)

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

    // MARK: - Incoming Message Handling (single decision input path)

    func handleIncomingMessage(
        id: UUID,
        conversationId: UUID,
        senderProfileId: UUID,
        content: String,
        createdAt: Date,
        conversation: Conversation?
    ) {
        guard markIncomingMessageProcessedIfNeeded(id) else { return }

        let incoming = Message(
            id: id,
            conversationId: conversationId,
            senderProfileId: senderProfileId,
            content: content,
            createdAt: createdAt
        )

        // Keep active thread live, without requiring a pull-to-refresh.
        if currentConversationId == conversationId && !currentMessages.contains(where: { $0.id == id }) {
            currentMessages.append(incoming)
        }

        if activeConversationId != conversationId {
            unreadByConversation[conversationId, default: 0] += 1
            totalUnreadCount = unreadByConversation.values.reduce(0, +)
        }

        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(totalUnreadCount)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount
        }

        if let conversation, !conversations.contains(where: { $0.id == conversation.id }) {
            conversations.insert(conversation, at: 0)
        }

        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            let convo = conversations.remove(at: index)
            conversations.insert(convo, at: 0)
        }
    }

    struct ConversationPreview: Equatable {
        let messageId: UUID
        let content: String
        let createdAt: Date?
    }

    func fetchConversationPreviews(conversationIds: [UUID]) async -> [UUID: ConversationPreview] {
        guard !conversationIds.isEmpty else { return [:] }

        struct ConversationMessageRow: Decodable {
            let id: UUID
            let conversationId: UUID
            let content: String
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case id
                case conversationId = "conversation_id"
                case content
                case createdAt = "created_at"
            }
        }

        do {
            let rows: [ConversationMessageRow] = try await supabase
                .from("messages")
                .select("id,conversation_id,content,created_at")
                .in("conversation_id", values: conversationIds.map(\.uuidString))
                .order("created_at", ascending: false)
                .limit(500)
                .execute()
                .value

            var previews: [UUID: ConversationPreview] = [:]
            for row in rows where previews[row.conversationId] == nil {
                previews[row.conversationId] = ConversationPreview(
                    messageId: row.id,
                    content: row.content,
                    createdAt: row.createdAt
                )
            }
            return previews
        } catch {
            print("[Messaging] ❌ Failed to fetch conversation previews: \(error)")
            return [:]
        }
    }

    private func markIncomingMessageProcessedIfNeeded(_ id: UUID) -> Bool {
        if processedIncomingMessageIds.contains(id) {
            return false
        }

        processedIncomingMessageIds.insert(id)
        processedIncomingOrder.append(id)

        if processedIncomingOrder.count > maxProcessedIncomingIds {
            let overflow = processedIncomingOrder.count - maxProcessedIncomingIds
            for _ in 0..<overflow {
                let removed = processedIncomingOrder.removeFirst()
                processedIncomingMessageIds.remove(removed)
            }
        }

        return true
    }

    func markConversationViewed(conversationId: UUID) {
        unreadByConversation[conversationId] = 0
        unreadByConversation = unreadByConversation.filter { $0.value > 0 }
        totalUnreadCount = unreadByConversation.values.reduce(0, +)
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(totalUnreadCount)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount
        }
    }

    func markConversationAsRead(_ conversationId: UUID) {
        markConversationViewed(conversationId: conversationId)
    }

    func setMessagesTabActive(_ isActive: Bool) {
        isMessagesTabActive = isActive
        if !isActive {
            visibleConversationIds.removeAll()
        }
    }

    func setConversationVisibility(conversationId: UUID, isVisible: Bool) {
        if isVisible {
            visibleConversationIds.insert(conversationId)
        } else {
            visibleConversationIds.remove(conversationId)
        }
    }

    func isConversationVisible(_ conversationId: UUID) -> Bool {
        visibleConversationIds.contains(conversationId)
    }

    func cacheProfileName(_ name: String, for profileId: UUID) {
        profileNameCache[profileId] = name
    }

    func cachedProfileName(for profileId: UUID) -> String? {
        profileNameCache[profileId]
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

    // MARK: - Event Context Lookup

    /// Returns the event name from an existing conversation with the target user, if any.
    /// Used by profile views to show "Met at [Event Name]" context.
    func eventName(forConversationWith targetProfileId: UUID) async -> String? {
        guard let myId = AuthService.shared.currentUser?.id else { return nil }

        let convos: [Conversation]? = try? await supabase
            .from("conversations")
            .select("*")
            .or("and(participant_a.eq.\(myId.uuidString),participant_b.eq.\(targetProfileId.uuidString)),and(participant_a.eq.\(targetProfileId.uuidString),participant_b.eq.\(myId.uuidString))")
            .limit(1)
            .execute()
            .value

        return convos?.first?.eventName
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
