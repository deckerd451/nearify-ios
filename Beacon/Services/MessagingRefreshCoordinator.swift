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

    enum Mode: String {
        case interactive = "interactive"
        case quiet = "quiet"

        var isNotificationEligible: Bool {
            self == .interactive
        }
    }

    static let shared = MessagingRefreshCoordinator()

    private let debounceWindow: TimeInterval = 2.5
    private let tabChangeDebounceWindow: TimeInterval = 5.0
    private let promptDelay: TimeInterval = 0.12
    private let highPriorityReasons: Set<Reason> = [.messageSent, .notificationOpened, .manualConversationOpen]

    private var pendingReasons: [Reason: Mode] = [:]
    private var pendingTask: Task<Void, Never>?
    private var isExecuting = false
    private var shouldRunFollowUp = false
    private var lastExecutionAt: Date = .distantPast
    private var lastRequestAtByReason: [Reason: Date] = [:]

    private init() {}

    func requestRefresh(reason: Reason, mode: Mode = .interactive) {
        let now = Date()
        let debounce = (reason == .tabChange) ? tabChangeDebounceWindow : debounceWindow

        if let last = lastRequestAtByReason[reason],
           now.timeIntervalSince(last) < debounce {
            print("[MessagingRefresh] coalesced reason=\(reason.rawValue)")
            return
        }
        lastRequestAtByReason[reason] = now

        let existingMode = pendingReasons[reason] ?? .quiet
        pendingReasons[reason] = mergedMode(existingMode, mode)

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
        let reasonsWithModes = pendingReasons
        pendingReasons.removeAll()

        _ = await MessagingService.shared.fetchConversationsSnapshot()

        for (reason, mode) in reasonsWithModes {
            await MessageNotificationCoordinator.shared.processRefresh(reason: reason, mode: mode)
        }

        lastExecutionAt = Date()
        isExecuting = false

        let reasonSummary = reasonsWithModes
            .map { "\($0.key.rawValue):\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
        print("[MessagingRefresh] executed reason=\(reasonSummary)")

        if shouldRunFollowUp || !pendingReasons.isEmpty {
            shouldRunFollowUp = false
            schedule(triggerReason: .controlledPoll)
        }
    }

    private func mergedMode(_ lhs: Mode, _ rhs: Mode) -> Mode {
        if lhs.isNotificationEligible || rhs.isNotificationEligible {
            return .interactive
        }
        return .quiet
    }
}
