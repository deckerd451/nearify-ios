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
    private var pollTask: Task<Void, Never>?
    private var lastProcessedAt: Date?
    private var isPolling = false

    /// Session-scoped dedupe for notifications that were either delivered or intentionally suppressed.
    private var notifiedMessageIds: Set<UUID> = []
    private var notifiedMessageOrder: [UUID] = []
    private let maxNotifiedMessageIds = 2_000

    /// Prevent duplicate rendering/processing from poll overlap.
    private var processedMessageIds: Set<UUID> = []
    private var processedMessageOrder: [UUID] = []
    private let maxProcessedMessageIds = 2_000

    /// Baseline to prevent notifications for historical bootstrap content.
    private var notificationBaselineDate = Date()

    private static let cursorDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private init() {
        notificationBaselineDate = Date()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
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
        MessagingRefreshCoordinator.shared.requestRefresh(reason: .notificationOpened)
    }

    func markConversationMessagesAsNotified(conversationId: UUID, messages: [Message]) {
        let ids = messages.filter { $0.conversationId == conversationId }.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach(markMessageNotified)
    }

    private func monitorLoop() async {
        while !Task.isCancelled {
            await pollOnce(reason: .controlledPoll, mode: .interactive)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func processRefresh(reason: MessagingRefreshCoordinator.Reason, mode: MessagingRefreshCoordinator.Mode) async {
        await pollOnce(reason: reason, mode: mode)
    }

    private func pollOnce(reason: MessagingRefreshCoordinator.Reason, mode: MessagingRefreshCoordinator.Mode) async {
        guard !isPolling else {
            print("[MessagingRefresh] coalesced reason=\(reason.rawValue)")
            return
        }
        guard let myId = AuthService.shared.currentUser?.id else { return }

        isPolling = true
        defer { isPolling = false }

        var conversations = MessagingService.shared.conversations
        if conversations.isEmpty {
            MessagingRefreshCoordinator.shared.requestRefresh(reason: .appActive)
            conversations = await MessagingService.shared.fetchConversationsSnapshot()
        }
        let conversationIds = conversations.map(\.id)
        guard !conversationIds.isEmpty else { return }

        do {
            let rows = try await fetchIncomingRows(
                conversationIds: conversationIds,
                excludingSenderId: myId
            )

            if lastProcessedAt == nil {
                if let newest = rows.last?.createdAt {
                    lastProcessedAt = newest
                }
                return
            }

            var newestSeenAt = lastProcessedAt
            var quietDuplicateCount = 0

            for row in rows {
                if newestSeenAt == nil || row.createdAt > newestSeenAt! {
                    newestSeenAt = row.createdAt
                }

                guard markMessageProcessedIfNeeded(row.id, shouldLogDuplicate: mode.isNotificationEligible) else {
                    if !mode.isNotificationEligible {
                        quietDuplicateCount += 1
                    }
                    continue
                }

                let message = Message(
                    id: row.id,
                    conversationId: row.conversationId,
                    senderProfileId: row.senderProfileId,
                    content: row.content,
                    createdAt: row.createdAt
                )

                let conversation = conversations.first { $0.id == row.conversationId }
                await handleIncoming(
                    message: message,
                    refreshReason: reason,
                    mode: mode,
                    conversation: conversation
                )
            }

            if !mode.isNotificationEligible && quietDuplicateCount > 0 {
                print("[Messaging] quiet refresh skipped \(quietDuplicateCount) duplicate messages")
            }

            if let newestSeenAt {
                lastProcessedAt = newestSeenAt
            }
        } catch {
            print("[MessageCoordinator] ❌ Poll failed: \(error)")
        }
    }

    private func fetchIncomingRows(
        conversationIds: [UUID],
        excludingSenderId myId: UUID
    ) async throws -> [IncomingMessageRow] {
        let conversationIdStrings = conversationIds.map(\.uuidString)

        let base = supabase
            .from("messages")
            .select("id,conversation_id,sender_profile_id,content,created_at")
            .in("conversation_id", values: conversationIdStrings)
            .neq("sender_profile_id", value: myId.uuidString)

        if let lastProcessedAt {
            let iso = Self.cursorDateFormatter.string(from: lastProcessedAt)

            return try await base
                .gt("created_at", value: iso)
                .order("created_at", ascending: true)
                .limit(50)
                .execute()
                .value
        } else {
            return try await base
                .order("created_at", ascending: true)
                .limit(50)
                .execute()
                .value
        }
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

    private func handleIncoming(
        message: Message,
        refreshReason: MessagingRefreshCoordinator.Reason,
        mode: MessagingRefreshCoordinator.Mode,
        conversation: Conversation?
    ) async {
        MessagingService.shared.handleIncomingMessage(
            id: message.id,
            conversationId: message.conversationId,
            senderProfileId: message.senderProfileId,
            content: message.content,
            createdAt: message.createdAt ?? Date(),
            conversation: conversation
        )

        guard mode.isNotificationEligible else { return }

        let context = MessagingNotificationContext(
            currentUserProfileId: AuthService.shared.currentUser?.id,
            activeConversationId: MessagingService.shared.activeConversationId,
            appLifecycleState: MessagingAppLifecycleState.from(UIApplication.shared.applicationState),
            notificationBaselineDate: notificationBaselineDate,
            notifiedMessageIds: notifiedMessageIds,
            refreshReason: refreshReason
        )

        let decision = MessageNotificationEligibility.decision(for: message, context: context)
        switch decision {
        case .blocked(let reason):
            print("[NotifyGate] blocked message=\(message.id) reason=\(reason.rawValue)")
            if reason == .activeConversation || reason == .beforeBaseline || reason == .tabChangeRefresh {
                markMessageNotified(message.id)
            }
            return
        case .allowed:
            print("[NotifyGate] allowed message=\(message.id) reason=\(refreshReason.rawValue)")
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

        FeedService.shared.requestRefresh(reason: "incoming-message")
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
