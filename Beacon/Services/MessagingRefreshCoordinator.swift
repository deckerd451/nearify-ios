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
        // Messaging refreshes are subscription-driven; explicit refresh requests are ignored.
        print("[MessagingRefresh] ignored reason=\(reason.rawValue) mode=\(mode.rawValue)")
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
        return
    }

    private func mergedMode(_ lhs: Mode, _ rhs: Mode) -> Mode {
        if lhs.isNotificationEligible || rhs.isNotificationEligible {
            return .interactive
        }
        return .quiet
    }
}
