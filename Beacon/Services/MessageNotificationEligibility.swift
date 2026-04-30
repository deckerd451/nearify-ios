import Foundation
import UIKit

enum MessagingAppLifecycleState {
    case foreground
    case background
    case inactive

    static func from(_ state: UIApplication.State) -> MessagingAppLifecycleState {
        switch state {
        case .active:
            return .foreground
        case .background:
            return .background
        case .inactive:
            return .inactive
        @unknown default:
            return .inactive
        }
    }
}

struct MessagingNotificationContext {
    let currentUserProfileId: UUID?
    let activeConversationId: UUID?
    let isMessagesTabActive: Bool
    let visibleConversationIds: Set<UUID>
    let appLifecycleState: MessagingAppLifecycleState
    let notificationBaselineDate: Date
    let notifiedMessageIds: Set<UUID>
    let refreshReason: MessagingRefreshCoordinator.Reason
}

enum NotifyGateBlockReason: String {
    case selfSent = "self-sent"
    case alreadyNotified = "already-notified"
    case beforeBaseline = "before-baseline"
    case activeConversation = "active-conversation"
    case messagesTabActive = "messages-tab-active"
    case conversationVisible = "conversation-visible"
    case tabChangeRefresh = "tab-change-refresh"
    case inappropriateState = "inappropriate-state"
}

enum NotifyGateDecision {
    case allowed
    case blocked(NotifyGateBlockReason)
}

enum MessageNotificationEligibility {
    static func shouldNotify(for message: Message, context: MessagingNotificationContext) -> Bool {
        if case .allowed = decision(for: message, context: context) {
            return true
        }
        return false
    }

    static func decision(for message: Message, context: MessagingNotificationContext) -> NotifyGateDecision {
        if context.refreshReason == .tabChange {
            return .blocked(.tabChangeRefresh)
        }

        guard let currentUserProfileId = context.currentUserProfileId else {
            return .blocked(.inappropriateState)
        }

        guard message.senderProfileId != currentUserProfileId else {
            return .blocked(.selfSent)
        }

        guard !context.notifiedMessageIds.contains(message.id) else {
            return .blocked(.alreadyNotified)
        }

        guard let createdAt = message.createdAt,
              createdAt >= context.notificationBaselineDate else {
            return .blocked(.beforeBaseline)
        }

        if context.activeConversationId == message.conversationId {
            return .blocked(.activeConversation)
        }

        if context.isMessagesTabActive {
            return .blocked(.messagesTabActive)
        }

        if context.visibleConversationIds.contains(message.conversationId) {
            return .blocked(.conversationVisible)
        }

        switch context.appLifecycleState {
        case .foreground, .background:
            return .allowed
        case .inactive:
            return .blocked(.inappropriateState)
        }
    }
}
