import Foundation

/// Decides whether to trigger a local notification for a ranked profile.
/// Uses the same scoring philosophy as EventIntelligenceService.
/// Currently logging-only — no actual notifications sent yet.
@MainActor
final class NotificationDecisionService {

    static let shared = NotificationDecisionService()

    /// Minimum score to trigger a notification.
    private let scoreThreshold: Double = 100

    /// Cooldown per profile to avoid duplicate notifications.
    private let cooldownSeconds: TimeInterval = 300 // 5 minutes

    /// Tracks last notification time per profile ID.
    private var lastNotified: [UUID: Date] = [:]

    private init() {}

    /// Evaluates ranked profiles and logs notification decisions.
    /// Call after EventIntelligenceService produces results.
    func evaluate(profiles: [RankedProfile]) {
        let now = Date()

        for profile in profiles {
            // Check score threshold
            guard profile.score >= scoreThreshold else {
                #if DEBUG
                print("[Notify] Skipped (low score) profile=\(profile.name) score=\(Int(profile.score)) threshold=\(Int(scoreThreshold))")
                #endif
                continue
            }

            // Check cooldown
            if let last = lastNotified[profile.profileId],
               now.timeIntervalSince(last) < cooldownSeconds {
                #if DEBUG
                print("[Notify] Skipped (duplicate) profile=\(profile.name) lastNotified=\(Int(now.timeIntervalSince(last)))s ago")
                #endif
                continue
            }

            // Would trigger notification
            lastNotified[profile.profileId] = now

            #if DEBUG
            print("[Notify] Triggered for profile=\(profile.name) score=\(Int(profile.score))")
            #endif

            // TODO: Send actual local notification
            // UNUserNotificationCenter.current().add(...)
        }
    }

    /// Clears notification history (e.g., when leaving an event).
    func reset() {
        lastNotified.removeAll()
    }
}
