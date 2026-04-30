import Foundation
import SwiftUI
import Supabase
import UIKit
import Combine

@MainActor
final class MessageNotificationCoordinator: ObservableObject {
    static let shared = MessageNotificationCoordinator()

    struct InAppBanner: Identifiable, Equatable {
        let id: UUID
        let conversationId: UUID
        let senderProfileId: UUID
        let senderName: String
        let preview: String
    }

    @Published private(set) var banner: InAppBanner?

    private let supabase = AppEnvironment.shared.supabaseClient
    var messageSubscription: RealtimeChannelV2?
    private var postgresInsertSubscription: RealtimeSubscription?
    private var statusSubscription: RealtimeSubscription?
    private var activeSubscriptionsCount = 0
    private var lastInsertReceivedAt: Date?

    /// Session-scoped dedupe for notifications that were either delivered or intentionally suppressed.
    private var notifiedMessageIds: Set<UUID> = []
    private var notifiedMessageOrder: [UUID] = []
    private let maxNotifiedMessageIds = 2_000

    /// Prevent duplicate rendering/processing from stream overlap.
    private var processedMessageIds: Set<UUID> = []
    private var processedMessageOrder: [UUID] = []
    private let maxProcessedMessageIds = 2_000

    /// Baseline to prevent notifications for historical bootstrap content.
    private var notificationBaselineDate = Date()
    private var knownConversationIds: Set<UUID> = []

    private init() {
        notificationBaselineDate = Date()
    }

    func start() {
        Task { [weak self] in
            await self?.ensureSingleActiveSubscription()
        }
    }

    func stop() {
        let existing = messageSubscription
        messageSubscription = nil
        postgresInsertSubscription = nil
        statusSubscription = nil
        lastInsertReceivedAt = nil
        activeSubscriptionsCount = 0

        Task {
            await existing?.unsubscribe()
        }

        print("[Messaging] Active subscriptions: 0")
    }

    func dismissBanner() {
        banner = nil
    }

    func markForegroundActive() {
        start()
    }

    func markNotificationOpened(messageId: UUID?) {
        if let messageId {
            markMessageNotified(messageId)
        }
    }

    func markConversationMessagesAsNotified(conversationId: UUID, messages: [Message]) {
        let ids = messages.filter { $0.conversationId == conversationId }.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach(markMessageNotified)
    }

    private func ensureSingleActiveSubscription() async {
        if let existing = messageSubscription {
            await existing.unsubscribe()
            messageSubscription = nil
            postgresInsertSubscription = nil
            statusSubscription = nil
        }

        guard let myId = AuthService.shared.currentUser?.id else { return }

        await refreshKnownConversationIds()

        print("[MessagingRT] channel creating")
        let channel = supabase.channel("messages-stream-\(myId.uuidString)")
        statusSubscription = channel.onStatusChange { status in
            print("[MessagingRT] subscribe status=\(status)")
        }
        postgresInsertSubscription = channel.onPostgresChange(InsertAction.self, schema: "public", table: "messages") { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                await self.handleRealtimeInsert(payload: payload, myId: myId)
            }
        }
        print("[MessagingRT] postgres change callback registered")

        do {
            try await channel.subscribeWithError()
        } catch {
            print("[Messaging] Failed to subscribe to realtime messages: \(error)")
            return
        }

        messageSubscription = channel
        lastInsertReceivedAt = nil
        activeSubscriptionsCount = messageSubscription == nil ? 0 : 1
        print("[MessagingRT] subscribed filter=schema:public table:messages event:INSERT")
        print("[Messaging] Active subscriptions: \(activeSubscriptionsCount)")

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.messageSubscription === channel else { return }
            guard self.lastInsertReceivedAt == nil else { return }
            print("[MessagingRT] no insert callbacks received; verify Supabase Realtime publication includes public.messages")
        }
    }

    func refreshKnownConversationIds() async {
        let _ = await MessagingService.shared.fetchConversationsSnapshot()
        knownConversationIds = Set(MessagingService.shared.conversations.map(\.id))
    }

    private func handleRealtimeInsert(payload: InsertAction, myId: UUID) async {
        guard
            let rowData = try? JSONSerialization.data(withJSONObject: payload.record),
            let row = try? JSONDecoder().decode(IncomingMessageRow.self, from: rowData)
        else { return }

        lastInsertReceivedAt = Date()
        print("[MessagingRT] insert received id=\(row.id) conversation=\(row.conversationId) sender=\(row.senderProfileId)")

        if knownConversationIds.isEmpty {
            await refreshKnownConversationIds()
        }

        guard knownConversationIds.contains(row.conversationId) else {
            print("[MessagingRT] ignored reason=unknown-conversation conversation=\(row.conversationId)")
            return
        }
        guard markMessageProcessedIfNeeded(row.id, shouldLogDuplicate: true) else { return }
        print("[MessagingRT] accepted incoming id=\(row.id)")

        let message = Message(
            id: row.id,
            conversationId: row.conversationId,
            senderProfileId: row.senderProfileId,
            content: row.content,
            createdAt: row.createdAt
        )

        let conversation = MessagingService.shared.conversations.first { $0.id == row.conversationId }
        MessagingService.shared.handleIncomingMessage(
            id: message.id,
            conversationId: message.conversationId,
            senderProfileId: message.senderProfileId,
            content: message.content,
            createdAt: message.createdAt ?? Date(),
            conversation: conversation
        )

        await evaluateNotification(for: message, myId: myId)

    }

    func evaluateIngestionNotification(for message: Message) async {
        let myId = AuthService.shared.currentUser?.id ?? message.senderProfileId
        await evaluateNotification(for: message, myId: myId)
    }

    private func markMessageProcessedIfNeeded(_ messageId: UUID, shouldLogDuplicate: Bool) -> Bool {
        if processedMessageIds.contains(messageId) {
            if shouldLogDuplicate {
                #if DEBUG
                print("[Messaging] duplicate message ignored: \(messageId)")
                #endif
            }
            return false
        }

        processedMessageIds.insert(messageId)
        processedMessageOrder.append(messageId)

        if processedMessageOrder.count > maxProcessedMessageIds {
            let overflow = processedMessageOrder.count - maxProcessedMessageIds
            for _ in 0..<overflow {
                let removed = processedMessageOrder.removeFirst()
                processedMessageIds.remove(removed)
            }
        }

        return true
    }

    private func markMessageNotified(_ messageId: UUID) {
        guard !notifiedMessageIds.contains(messageId) else { return }
        notifiedMessageIds.insert(messageId)
        notifiedMessageOrder.append(messageId)

        if notifiedMessageOrder.count > maxNotifiedMessageIds {
            let overflow = notifiedMessageOrder.count - maxNotifiedMessageIds
            for _ in 0..<overflow {
                let removed = notifiedMessageOrder.removeFirst()
                notifiedMessageIds.remove(removed)
            }
        }
    }

    private func resolveName(for profileId: UUID) async -> String {
        if let cached = MessagingService.shared.cachedProfileName(for: profileId) {
            return cached
        }

        if let profile = try? await ProfileService.shared.fetchProfileById(profileId) {
            MessagingService.shared.cacheProfileName(profile.name, for: profileId)
            return profile.name
        }

        return "Someone"
    }

    private func evaluateNotification(for message: Message, myId: UUID) async {
        let currentUserProfileId = AuthService.shared.currentUser?.id ?? myId
        let activeConversationId = MessagingService.shared.activeConversationId
        let currentTabIsMessages = MessagingService.shared.isMessagesTabActive
        let isOwnMessage = message.senderProfileId == currentUserProfileId
        let isViewingConversation = activeConversationId == message.conversationId
        let currentTabLog = currentTabIsMessages ? "messages" : "other"
        let openConversationLog = activeConversationId?.uuidString ?? "nil"

        print("""
[NotifyGate] evaluating message=\(message.id)
sender=\(message.senderProfileId)
currentUser=\(currentUserProfileId)
conversation=\(message.conversationId)
tab=\(currentTabLog)
openConversation=\(openConversationLog)
isOwnMessage=\(isOwnMessage)
isAlreadyViewing=\(currentTabIsMessages && isViewingConversation)
""")

        if isOwnMessage {
            print("[Notify] suppressed reason=own-message")
            return
        }

        if currentTabIsMessages && isViewingConversation {
            print("[Notify] suppressed reason=already-viewing")
            markMessageNotified(message.id)
            return
        }

        let context = MessagingNotificationContext(
            currentUserProfileId: AuthService.shared.currentUser?.id,
            activeConversationId: MessagingService.shared.activeConversationId,
            isMessagesTabActive: MessagingService.shared.isMessagesTabActive,
            visibleConversationIds: MessagingService.shared.visibleConversationIds,
            appLifecycleState: MessagingAppLifecycleState.from(UIApplication.shared.applicationState),
            notificationBaselineDate: notificationBaselineDate,
            notifiedMessageIds: notifiedMessageIds,
            refreshReason: .manual
        )

        let decision = MessageNotificationEligibility.decision(for: message, context: context)
        switch decision {
        case .blocked(let reason):
            print("[Notify] suppressed reason=\(reason.rawValue)")
            if reason == .activeConversation || reason == .beforeBaseline || reason == .tabChangeRefresh || reason == .conversationVisible {
                markMessageNotified(message.id)
            }
            return
        case .allowed:
            break
        }

        markMessageNotified(message.id)
        let senderName = await resolveName(for: message.senderProfileId)

        showInAppBanner(message, senderName: senderName, appState: context.appLifecycleState)
    }

    private func showInAppBanner(_ message: Message, senderName: String, appState: MessagingAppLifecycleState) {
        switch appState {
        case .foreground:
            banner = InAppBanner(
                id: message.id,
                conversationId: message.conversationId,
                senderProfileId: message.senderProfileId,
                senderName: senderName,
                preview: String(message.content.prefix(72))
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            print("[Notify] banner shown message=\(message.id)")
        case .background:
            NotificationService.shared.sendMessageNotification(
                messageId: message.id,
                fromName: senderName,
                preview: message.content
            )
            print("[Notify] local notification scheduled message=\(message.id)")
        case .inactive:
            print("[Notify] suppressed reason=inappropriate-state")
            break
        }
    }
}

private struct IncomingMessageRow: Decodable {
    let id: UUID
    let conversationId: UUID
    let senderProfileId: UUID
    let content: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case senderProfileId = "sender_profile_id"
        case content
        case createdAt = "created_at"
    }
}
