import Foundation

/// Coordinates conversation list refresh requests so we avoid bursty duplicate loads.
@MainActor
final class MessagingRefreshCoordinator {

    enum Reason: String, Hashable {
        case appActive = "app-active"
        case tabChange = "tab-change"
        case messageSent = "message-sent"
        case manual = "manual"
    }

    enum Mode: String {
        case interactive = "interactive"
        case quiet = "quiet"

        var isNotificationEligible: Bool {
            self == .interactive
        }
    }

    static let shared = MessagingRefreshCoordinator()

    private let minimumRefreshInterval: TimeInterval = 1.5

    private var pendingReasons: [Reason: Mode] = [:]
    private var pendingTask: Task<Void, Never>?
    private var isExecuting = false
    private var shouldRunFollowUp = false
    private var lastExecutionAt: Date = .distantPast
    private var queuedRefresh = false

    private init() {}

    func requestRefresh(reason: Reason, mode: Mode = .interactive) {
        let now = Date()
        if reason == .tabChange { return }
        if reason == .appActive, now.timeIntervalSince(lastExecutionAt) < 10 { return }

        let existingMode = pendingReasons[reason] ?? .quiet
        pendingReasons[reason] = mergedMode(existingMode, mode)

        if isExecuting {
            shouldRunFollowUp = true
            print("[MessagingRefresh] coalesced reason=\(reason.rawValue)")
            return
        }

        schedule(triggerReason: reason, now: now)
    }

    private func schedule(triggerReason: Reason, now: Date) {
        pendingTask?.cancel()
        let elapsed = now.timeIntervalSince(lastExecutionAt)
        let delay = max(0, minimumRefreshInterval - elapsed)

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
            schedule(triggerReason: .manual, now: Date())
        }
    }

    private func mergedMode(_ lhs: Mode, _ rhs: Mode) -> Mode {
        if lhs.isNotificationEligible || rhs.isNotificationEligible {
            return .interactive
        }
        return .quiet
    }
}
