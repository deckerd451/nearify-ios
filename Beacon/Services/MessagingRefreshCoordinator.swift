import Foundation

/// Coordinates conversation list refresh requests so we avoid bursty duplicate loads.
@MainActor
final class MessagingRefreshCoordinator {

    enum Reason: String, Hashable {
        case appActive = "app-active"
        case tabChange = "tab-change"
        case messageSent = "message-sent"
        case notificationOpened = "notification-opened"
        case manualConversationOpen = "manual-conversation-open"
        case controlledPoll = "controlled-poll"
    }

    static let shared = MessagingRefreshCoordinator()

    private let debounceWindow: TimeInterval = 2.5
    private let promptDelay: TimeInterval = 0.12
    private let highPriorityReasons: Set<Reason> = [.messageSent, .notificationOpened, .manualConversationOpen]

    private var pendingReasons: Set<Reason> = []
    private var pendingTask: Task<Void, Never>?
    private var isExecuting = false
    private var shouldRunFollowUp = false
    private var lastExecutionAt: Date = .distantPast
    private var lastRequestAtByReason: [Reason: Date] = [:]

    private init() {}

    func requestRefresh(reason: Reason) {
        let now = Date()

        if let last = lastRequestAtByReason[reason],
           now.timeIntervalSince(last) < debounceWindow {
            print("[MessagingRefresh] coalesced reason=\(reason.rawValue)")
            return
        }
        lastRequestAtByReason[reason] = now

        pendingReasons.insert(reason)

        if isExecuting {
            shouldRunFollowUp = true
            print("[MessagingRefresh] coalesced reason=\(reason.rawValue)")
            return
        }

        schedule(triggerReason: reason)
    }

    private func schedule(triggerReason: Reason) {
        pendingTask?.cancel()

        let delay: TimeInterval
        if highPriorityReasons.contains(triggerReason) {
            delay = promptDelay
        } else {
            let elapsed = Date().timeIntervalSince(lastExecutionAt)
            delay = max(0.2, debounceWindow - elapsed)
        }

        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.executeRefresh(triggerReason: triggerReason)
        }
    }

    private func executeRefresh(triggerReason: Reason) async {
        guard !isExecuting else {
            shouldRunFollowUp = true
            print("[MessagingRefresh] coalesced reason=\(triggerReason.rawValue)")
            return
        }

        guard !pendingReasons.isEmpty else { return }

        isExecuting = true
        let reasons = pendingReasons
        pendingReasons.removeAll()

        _ = await MessagingService.shared.fetchConversationsSnapshot()
        lastExecutionAt = Date()
        isExecuting = false

        let reasonSummary = reasons.map(\.rawValue).sorted().joined(separator: ",")
        print("[MessagingRefresh] executed reason=\(reasonSummary)")

        if shouldRunFollowUp || !pendingReasons.isEmpty {
            shouldRunFollowUp = false
            schedule(triggerReason: .controlledPoll)
        }
    }
}
