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
    var messageSubscription: RealtimeChannel?
    private var activeSubscriptionsCount = 0

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

    private init() {
        notificationBaselineDate = Date()
    }

    func start() {
        Task { [weak self] in
            await self?.ensureSingleActiveSubscription()
        }
    }

    func stop() {
        messageSubscription?.unsubscribe()
        messageSubscription = nil
        activeSubscriptionsCount = 0
        print("[Messaging] Active subscriptions: \(activeSubscriptionsCount)")
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
        messageSubscription?.unsubscribe()
        messageSubscription = nil

        guard let myId = AuthService.shared.currentUser?.id else { return }

        let _ = await MessagingService.shared.fetchConversationsSnapshot()
        let conversations = MessagingService.shared.conversations
        let conversationIds = Set(conversations.map(\.id.uuidString))
        guard !conversationIds.isEmpty else { return }

        let channel = supabase.channel("messages-stream-\(myId.uuidString)")
        channel.onPostgresChange(InsertAction.self, schema: "public", table: "messages") { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                await self.handleRealtimeInsert(payload: payload, myId: myId, conversationIds: conversationIds)
            }
        }
        await channel.subscribe()

        messageSubscription = channel
        activeSubscriptionsCount = messageSubscription == nil ? 0 : 1
        print("[Messaging] Active subscriptions: \(activeSubscriptionsCount)")
    }

    private func handleRealtimeInsert(payload: InsertAction, myId: UUID, conversationIds: Set<String>) async {
        guard
            let rowData = try? JSONSerialization.data(withJSONObject: payload.record),
            let row = try? JSONDecoder().decode(IncomingMessageRow.self, from: rowData)
        else { return }

        guard conversationIds.contains(row.conversationId.uuidString) else { return }
        guard row.senderProfileId != myId else { return }
        guard markMessageProcessedIfNeeded(row.id, shouldLogDuplicate: true) else { return }

        let message = Message(
            id: row.id,
            conversationId: row.conversationId,
            senderProfileId: row.senderProfileId,
            content: row.content,
            createdAt: row.createdAt
        )

        let conversation = MessagingService.shared.conversations.first { $0.id == row.conversationId }
        await handleIncoming(message: message, conversation: conversation)
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

    private func handleIncoming(message: Message, conversation: Conversation?) async {
        MessagingService.shared.handleIncomingMessage(
            id: message.id,
            conversationId: message.conversationId,
            senderProfileId: message.senderProfileId,
            content: message.content,
            createdAt: message.createdAt ?? Date(),
            conversation: conversation
        )

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
            print("[NotifyGate] blocked message=\(message.id) reason=\(reason.rawValue)")
            if reason == .activeConversation || reason == .beforeBaseline || reason == .tabChangeRefresh || reason == .messagesTabActive || reason == .conversationVisible {
                markMessageNotified(message.id)
            }
            return
        case .allowed:
            print("[NotifyGate] allowed message=\(message.id) reason=manual")
        }

        markMessageNotified(message.id)
        let senderName = await resolveName(for: message.senderProfileId)

        switch context.appLifecycleState {
        case .foreground:
            banner = InAppBanner(
                id: message.id,
                conversationId: message.conversationId,
                senderProfileId: message.senderProfileId,
                senderName: senderName,
                preview: String(message.content.prefix(72))
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .background:
            NotificationService.shared.sendMessageNotification(
                messageId: message.id,
                fromName: senderName,
                preview: message.content
            )
        case .inactive:
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
