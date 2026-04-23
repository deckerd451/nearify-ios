import Foundation

/// Coordinates People intelligence refresh signals from multiple sources and
/// coalesces them into a single debounced rebuild request.
@MainActor
final class PeopleRefreshCoordinator {

    static let shared = PeopleRefreshCoordinator()

    private let debounceWindow: TimeInterval = 1.8
    private let priorityReasons: Set<String> = [
        "attendees", "people-appear", "people-pull", "network-appear"
    ]

    private var pendingReasons = Set<String>()
    private var pendingTask: Task<Void, Never>?
    private(set) var lastRefreshTime: Date = .distantPast

    private init() { }

    func requestRefresh(reason: String) {
        pendingReasons.insert(reason)
        scheduleDebouncedFire(triggerReason: reason)
    }

    private func scheduleDebouncedFire(triggerReason: String) {
        pendingTask?.cancel()

        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefreshTime)
        let delay = max(0, debounceWindow - elapsed)
        let requestedDelay = priorityReasons.contains(triggerReason) ? max(0.2, delay * 0.4) : max(0.2, delay)

        pendingTask = Task { [weak self] in
            let sleepNs = UInt64(requestedDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        guard !pendingReasons.isEmpty else { return }

        let reasons = pendingReasons.sorted()
        pendingReasons.removeAll()
        lastRefreshTime = Date()

        let reasonSummary = reasons.joined(separator: ", ")
        PeopleIntelligenceController.shared.scheduleRebuild(reason: "coalesced: \(reasonSummary)")

        #if DEBUG
        print("[People] rebuild: COALESCED (\(reasonSummary))")
        #endif
    }
}
