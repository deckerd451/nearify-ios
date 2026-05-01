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
    /// Session-persistent hard dedupe set (not reset per refresh).
    private var processedMessageIds: Set<UUID> = []
    private var conversationLastMessageAt: [UUID: Date] = [:]
    private var conversationLastSenderId: [UUID: UUID] = [:]
    private var conversationLastReadAt: [UUID: Date] = [:]
    private var openedConversationId: UUID?
    private var fallbackPollTask: Task<Void, Never>?
    private var fallbackPollingConversationId: UUID?
    private var isAppActive = true

    private init() {}

    enum MessageIngestMode {
        case fullHistoryLoad
        case incrementalHistory
        case realtimeInsert
    }

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
            await MainActor.run {
                self.conversations = sorted
                self.recalculateUnreadCount()
                self.syncBadgeCount()
            }

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
        var latestSenderByConversation: [UUID: UUID] = [:]

        await withTaskGroup(of: (UUID, LastMessageSummary?).self) { group in
            for convo in convos {
                group.addTask { [supabase] in
                    let latestMessage: LastMessageSummary?
                    do {
                        let row: [LastMessageRow] = try await supabase
                            .from("messages")
                            .select("created_at,sender_profile_id")
                            .eq("conversation_id", value: convo.id.uuidString)
                            .order("created_at", ascending: false)
                            .limit(1)
                            .execute()
                            .value
                        latestMessage = row.first.map { LastMessageSummary(createdAt: $0.createdAt, senderProfileId: $0.senderProfileId) }
                    } catch {
                        latestMessage = nil
                    }

                    return (convo.id, latestMessage)
                }
            }

            for await (id, latestMessage) in group {
                latestByConversation[id] = latestMessage?.createdAt
                latestSenderByConversation[id] = latestMessage?.senderProfileId
            }
        }

        updateUIState {
            conversationLastMessageAt.merge(latestByConversation) { _, new in new }
            conversationLastSenderId.merge(latestSenderByConversation) { _, new in new }
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

            updateUIState {
                currentConversationId = conversationId
                ingest(messages: msgs, mode: .fullHistoryLoad)
            }

            #if DEBUG
            print("[Messaging] ✅ Loaded \(msgs.count) messages for conversation \(conversationId)")
            print("[Messaging] full history loaded count=\(msgs.count) conversation=\(conversationId)")
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

        let inserted: Message = try await supabase
            .from("messages")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value

        handleIncomingMessage(
            id: inserted.id,
            conversationId: inserted.conversationId,
            senderProfileId: inserted.senderProfileId,
            content: inserted.content,
            createdAt: inserted.createdAt ?? Date(),
            conversation: conversations.first(where: { $0.id == conversationId })
        )

        #if DEBUG
        print("[Messaging] ✅ Sent message in conversation \(conversationId)")
        #endif
    }

    // MARK: - Incoming Message Handling (single decision input path)

    func ingest(messages: [Message], mode: MessageIngestMode) {
        switch mode {
        case .fullHistoryLoad:
            let sorted = messages.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            currentMessages = sorted
            for message in sorted {
                processedMessageIds.insert(message.id)
                conversationLastMessageAt[message.conversationId] = message.createdAt ?? Date()
                conversationLastSenderId[message.conversationId] = message.senderProfileId
            }
            recalculateUnreadCount()
            syncBadgeCount()

        case .incrementalHistory:
            guard !messages.isEmpty else { return }
            var merged = currentMessages
            var newMessages: [Message] = []
            for message in messages.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                let isNew = !processedMessageIds.contains(message.id)
                if isNew {
                    processedMessageIds.insert(message.id)
                    newMessages.append(message)
                }
                if !merged.contains(where: { $0.id == message.id }) {
                    merged.append(message)
                }
                conversationLastMessageAt[message.conversationId] = message.createdAt ?? Date()
                conversationLastSenderId[message.conversationId] = message.senderProfileId
            }
            currentMessages = merged.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            recalculateUnreadCount()
            syncBadgeCount()

            // Evaluate notifications for genuinely new messages discovered by the poller
            for message in newMessages {
                Task { [message] in
                    await MessageNotificationCoordinator.shared.evaluateIngestionNotification(for: message)
                }
            }

        case .realtimeInsert:
            for message in messages {
                if processedMessageIds.contains(message.id) {
                    print("[Messaging] realtime insert skipped duplicate id=\(message.id)")
                    continue
                }
                processedMessageIds.insert(message.id)
                print("[Messaging] realtime insert accepted id=\(message.id)")
                appendToConversation(message)
                Task { [message] in
                    await MessageNotificationCoordinator.shared.evaluateIngestionNotification(for: message)
                }
            }
        }
    }

    private func appendToConversation(_ message: Message) {
        conversationLastMessageAt[message.conversationId] = message.createdAt ?? Date()
        conversationLastSenderId[message.conversationId] = message.senderProfileId

        if currentConversationId == message.conversationId && !currentMessages.contains(where: { $0.id == message.id }) {
            currentMessages.append(message)
        }

        recalculateUnreadCount()
        syncBadgeCount()

        if let index = conversations.firstIndex(where: { $0.id == message.conversationId }) {
            let convo = conversations.remove(at: index)
            conversations.insert(convo, at: 0)
        }
    }

    /// Pushes the current totalUnreadCount to the system badge.
    /// Called from every ingest path so the badge stays in sync.
    private func syncBadgeCount() {
        let count = totalUnreadCount
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    func handleIncomingMessage(
        id: UUID,
        conversationId: UUID,
        senderProfileId: UUID,
        content: String,
        createdAt: Date,
        conversation: Conversation?
    ) {
        let incoming = Message(
            id: id,
            conversationId: conversationId,
            senderProfileId: senderProfileId,
            content: content,
            createdAt: createdAt
        )
        ingest(messages: [incoming], mode: .realtimeInsert)

        if let conversation, !conversations.contains(where: { $0.id == conversation.id }) {
            conversations.insert(conversation, at: 0)
        }
    }

    struct ConversationPreview: Equatable {
        let messageId: UUID
        let content: String
        let createdAt: Date?
    }

    private struct LastMessageRow: Decodable {
        let createdAt: Date
        let senderProfileId: UUID

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case senderProfileId = "sender_profile_id"
        }
    }

    private struct LastMessageSummary {
        let createdAt: Date
        let senderProfileId: UUID
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

    func clearOpenedConversation(_ conversationId: UUID?) {
        guard openedConversationId == conversationId else { return }
        openedConversationId = nil
    }

    func markConversationOpenedOnce(conversationId: UUID) {
        guard openedConversationId != conversationId else { return }

        openedConversationId = conversationId
        conversationLastReadAt[conversationId] = Date()
        recalculateUnreadCount()

        print("[MessagesBadge] cleared conversation=\(conversationId)")
        print("[MessagesBadge] unread count=\(totalUnreadCount)")

        syncBadgeCount()
    }


    func setMessagesTabActive(_ isActive: Bool) {
        isMessagesTabActive = isActive
        if !isActive {
            visibleConversationIds.removeAll()
        }
        evaluateFallbackPollingState(reason: isActive ? "messages-tab-active" : "messages-tab-inactive")
    }

    func setConversationVisibility(conversationId: UUID, isVisible: Bool) {
        if isVisible {
            visibleConversationIds.insert(conversationId)
        } else {
            visibleConversationIds.remove(conversationId)
        }
        evaluateFallbackPollingState(reason: isVisible ? "conversation-visible" : "conversation-hidden")
    }

    func isConversationVisible(_ conversationId: UUID) -> Bool {
        visibleConversationIds.contains(conversationId)
    }

    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
        evaluateFallbackPollingState(reason: isActive ? "app-active" : "app-background")
    }

    func cacheProfileName(_ name: String, for profileId: UUID) {
        profileNameCache[profileId] = name
    }

    func cachedProfileName(for profileId: UUID) -> String? {
        profileNameCache[profileId]
    }

    func lastReadAt(for conversationId: UUID) -> Date? {
        conversationLastReadAt[conversationId]
    }

    func lastMessageAt(for conversationId: UUID) -> Date? {
        conversationLastMessageAt[conversationId]
    }

    func isCurrentConversation(_ conversationId: UUID) -> Bool {
        currentConversationId == conversationId
    }

    @MainActor
    func updateUIState(_ updates: () -> Void) {
        updates()
    }

    private func evaluateFallbackPollingState(reason: String) {
        guard isAppActive else {
            stopFallbackPolling(reason: reason)
            return
        }
        guard isMessagesTabActive, let conversationId = activeConversationId, visibleConversationIds.contains(conversationId) else {
            stopFallbackPolling(reason: reason)
            return
        }
        startFallbackPollingIfNeeded(conversationId: conversationId)
    }

    private func startFallbackPollingIfNeeded(conversationId: UUID) {
        if fallbackPollingConversationId == conversationId, fallbackPollTask != nil {
            return
        }
        stopFallbackPolling(reason: "switch-conversation")
        fallbackPollingConversationId = conversationId
        print("[MessagingFallback] polling started conversation=\(conversationId)")

        fallbackPollTask = Task { [weak self] in
            var cycle = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollForNewMessages(conversationId: conversationId)

                // Realtime callbacks can be unavailable in some environments.
                // Periodically refresh conversation snapshots so unread badge and
                // ordering still update for messages in non-visible threads.
                cycle += 1
                if cycle % 3 == 0 {
                    _ = await self.fetchConversationsSnapshot()
                }

                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func stopFallbackPolling(reason: String) {
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
        fallbackPollingConversationId = nil
        print("[MessagingFallback] polling stopped reason=\(reason)")
    }

    private func pollForNewMessages(conversationId: UUID) async {
        let baselineDate = conversationLastMessageAt[conversationId] ?? .distantPast
        let iso = ISO8601DateFormatter().string(from: baselineDate)
        do {
            let msgs: [Message] = try await supabase
                .from("messages")
                .select("*")
                .eq("conversation_id", value: conversationId.uuidString)
                .gt("created_at", value: iso)
                .order("created_at", ascending: true)
                .limit(100)
                .execute()
                .value

            guard !msgs.isEmpty else { return }
            updateUIState {
                ingest(messages: msgs, mode: .incrementalHistory)
            }
            print("[MessagingFallback] fetched new count=\(msgs.count)")
        } catch {
            print("[MessagingFallback] poll error=\(error)")
        }
    }

    private func recalculateUnreadCount() {
        guard let myId = AuthService.shared.currentUser?.id else {
            totalUnreadCount = 0
            return
        }

        var unread = 0
        for conversation in conversations {
            let lastMessageAt = conversationLastMessageAt[conversation.id]
            let lastSenderId = conversationLastSenderId[conversation.id]
            let lastReadAt = conversationLastReadAt[conversation.id] ?? .distantPast

            guard let msgAt = lastMessageAt, let senderId = lastSenderId else {
                #if DEBUG
                print("[MessagesBadge] skip convo=\(conversation.id) reason=missing-data hasMessageAt=\(lastMessageAt != nil) hasSenderId=\(lastSenderId != nil)")
                #endif
                continue
            }

            let isFromOther = senderId != myId
            let isAfterRead = msgAt > lastReadAt

            if isFromOther && isAfterRead {
                unread += 1
                #if DEBUG
                print("[MessagesBadge] unread convo=\(conversation.id) sender=\(senderId) msgAt=\(msgAt) readAt=\(lastReadAt)")
                #endif
            } else {
                #if DEBUG
                print("[MessagesBadge] read convo=\(conversation.id) isFromOther=\(isFromOther) isAfterRead=\(isAfterRead) sender=\(senderId)")
                #endif
            }
        }

        totalUnreadCount = unread
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
            await MessageNotificationCoordinator.shared.refreshKnownConversationIds()
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

        await MessageNotificationCoordinator.shared.refreshKnownConversationIds()
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
