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

    private init() {}

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

    private func monitorLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func pollOnce() async {
        guard !isPolling else { return }
        guard let myId = AuthService.shared.currentUser?.id else { return }

        isPolling = true
        defer { isPolling = false }

        let conversations = await MessagingService.shared.fetchConversationsSnapshot()
        let conversationIds = conversations.map(\.id)
        guard !conversationIds.isEmpty else { return }

        do {
            let rows = try await fetchIncomingRows(
                conversationIds: conversationIds,
                excludingSenderId: myId
            )

            if lastProcessedAt == nil {
                if let newest = rows.last?.createdAt {
                    // Bootstrap baseline so we don't notify historical messages.
                    lastProcessedAt = newest
                }
                return
            }

            for row in rows {
                let conversation = conversations.first { $0.id == row.conversationId }

                await handleIncoming(
                    messageId: row.id,
                    conversationId: row.conversationId,
                    senderProfileId: row.senderProfileId,
                    senderName: await resolveName(for: row.senderProfileId),
                    preview: row.content,
                    createdAt: row.createdAt,
                    conversation: conversation
                )
            }

            if let newest = rows.last?.createdAt {
                lastProcessedAt = newest
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
            let iso = ISO8601DateFormatter().string(from: lastProcessedAt)

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

    private func resolveName(for profileId: UUID) async -> String {
        if let cached = await MessagingService.shared.cachedProfileName(for: profileId) {
            return cached
        }

        if let profile = try? await ProfileService.shared.fetchProfileById(profileId) {
            await MessagingService.shared.cacheProfileName(profile.name, for: profileId)
            return profile.name
        }

        return "Someone"
    }

    private func handleIncoming(
        messageId: UUID,
        conversationId: UUID,
        senderProfileId: UUID,
        senderName: String,
        preview: String,
        createdAt: Date,
        conversation: Conversation?
    ) async {
        let appState = UIApplication.shared.applicationState

        await MessagingService.shared.handleIncomingMessage(
            id: messageId,
            conversationId: conversationId,
            senderProfileId: senderProfileId,
            content: preview,
            createdAt: createdAt,
            conversation: conversation
        )

        let isActiveConversation = MessagingService.shared.activeConversationId == conversationId

        if appState == .active {
            guard !isActiveConversation else {
                FeedService.shared.requestRefresh(reason: "incoming-message")
                return
            }

            banner = InAppBanner(
                id: messageId,
                conversationId: conversationId,
                senderProfileId: senderProfileId,
                senderName: senderName,
                preview: String(preview.prefix(72))
            )

            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            guard !isActiveConversation else {
                FeedService.shared.requestRefresh(reason: "incoming-message")
                return
            }

            NotificationService.shared.sendMessageNotification(
                messageId: messageId,
                fromName: senderName,
                preview: preview
            )
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
