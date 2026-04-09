import Foundation
import UserNotifications

/// Intelligent local notification system for Nearify.
/// Reactive, lightweight, deterministic. No backend tables, no push infra.
/// Notifications feel like: "this matters right now."
@MainActor
final class NotificationService {

    static let shared = NotificationService()

    // MARK: - Cooldown Constants

    private enum Cooldown {
        static let message: TimeInterval    = 45    // 45s between message notifications per person
        static let encounter: TimeInterval  = 600   // 10 min between encounter notifications per person
        static let intelligence: TimeInterval = 900  // 15 min between "you should meet" per person
        static let connection: TimeInterval = 60     // 1 min (mostly one-shot)
        static let missedOpportunity: TimeInterval = 1200 // 20 min
    }

    // MARK: - Thresholds

    private enum Threshold {
        static let encounterOverlapSeconds: Int = 120   // 2 min minimum to notify
        static let intelligenceScore: Double = 50       // minimum ranked score to notify
    }

    // MARK: - State

    /// Tracks last notification time per dedupe key (type:profileId).
    private var lastNotified: [String: Date] = [:]

    /// Profile ID of the conversation currently being viewed (suppress message notifications).
    var activeConversationProfileId: UUID?

    private init() {
        requestPermission()
    }

    // MARK: - Permission

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            #if DEBUG
            print("[Notify] Permission granted: \(granted), error: \(error?.localizedDescription ?? "none")")
            #endif
        }
    }

    // MARK: - Public API

    /// Evaluate feed items after a refresh. Checks for new messages from others.
    func evaluateFeedItems(_ items: [FeedItem]) {
        guard let myId = AuthService.shared.currentUser?.id else { return }

        for item in items where item.feedType == .message {
            guard let actorId = item.actorProfileId, actorId != myId else { continue }
            guard let ts = item.createdAt, Date().timeIntervalSince(ts) < 600 else { continue }

            let name = item.metadata?.actorName ?? "Someone"
            let preview = item.metadata?.messagePreview

            onMessageReceived(
                fromProfileId: actorId,
                fromName: name,
                preview: preview
            )
        }
    }

    /// Evaluate event intelligence results. Notify using insight text when available.
    func evaluateEventIntelligence(_ profiles: [RankedProfile]) {
        for profile in profiles {
            guard profile.score >= Threshold.intelligenceScore else { continue }
            guard !profile.isConnected else { continue }

            let key = "intelligence:\(profile.profileId)"
            guard !isCoolingDown(key: key, cooldown: Cooldown.intelligence) else {
                #if DEBUG
                print("[Notify] Intel skip (cooldown): \(profile.name)")
                #endif
                continue
            }

            markNotified(key: key)

            let body = profile.insight?.insightText ?? "You should meet \(profile.name)"

            send(
                title: "At this event",
                body: body,
                identifier: key
            )

            #if DEBUG
            print("[Notify] Intel triggered: \(profile.name) score=\(Int(profile.score)) need=\(profile.insight?.needState.rawValue ?? "none")")
            #endif
        }
    }

    /// Called when a message is received (or detected in feed).
    func onMessageReceived(fromProfileId: UUID, fromName: String, preview: String?) {
        // Don't notify if user is currently viewing this conversation
        if activeConversationProfileId == fromProfileId {
            #if DEBUG
            print("[Notify] Message skip (active conversation): \(fromName)")
            #endif
            return
        }

        let key = "message:\(fromProfileId)"
        guard !isCoolingDown(key: key, cooldown: Cooldown.message) else {
            #if DEBUG
            print("[Notify] Message skip (cooldown): \(fromName)")
            #endif
            return
        }

        markNotified(key: key)

        let body: String
        if let preview = preview, !preview.isEmpty {
            body = "\(fromName) replied — keep the conversation going"
        } else {
            body = "\(fromName) sent you a message"
        }

        send(
            title: "New message",
            body: body,
            identifier: key
        )

        #if DEBUG
        print("[Notify] Message triggered: \(fromName)")
        #endif
    }

    /// Called after an encounter is flushed to DB.
    func onEncounterDetected(profileId: UUID, profileName: String?, overlapSeconds: Int, isConnected: Bool) {
        guard overlapSeconds >= Threshold.encounterOverlapSeconds else {
            #if DEBUG
            print("[Notify] Encounter skip (short overlap): \(profileName ?? "?") \(overlapSeconds)s")
            #endif
            return
        }

        guard !isConnected else {
            #if DEBUG
            print("[Notify] Encounter skip (already connected): \(profileName ?? "?")")
            #endif
            return
        }

        let key = "encounter:\(profileId)"
        guard !isCoolingDown(key: key, cooldown: Cooldown.encounter) else {
            #if DEBUG
            print("[Notify] Encounter skip (cooldown): \(profileName ?? "?")")
            #endif
            return
        }

        markNotified(key: key)

        let name = profileName ?? "someone"
        send(
            title: "Nearby encounter",
            body: "You've been near \(name) — connect now",
            identifier: key
        )

        #if DEBUG
        print("[Notify] Encounter triggered: \(name) (\(overlapSeconds)s)")
        #endif
    }

    /// Called after a new connection is created.
    func onConnectionCreated(profileId: UUID, profileName: String?) {
        let key = "connection:\(profileId)"
        guard !isCoolingDown(key: key, cooldown: Cooldown.connection) else { return }

        markNotified(key: key)

        let name = profileName ?? "someone"
        send(
            title: "New connection",
            body: "You connected with \(name)",
            identifier: key
        )

        #if DEBUG
        print("[Notify] Connection triggered: \(name)")
        #endif
    }

    /// Clears all cooldown state (e.g., when leaving an event).
    func reset() {
        lastNotified.removeAll()
        activeConversationProfileId = nil
    }

    // MARK: - Cooldown Logic

    private func isCoolingDown(key: String, cooldown: TimeInterval) -> Bool {
        guard let last = lastNotified[key] else { return false }
        return Date().timeIntervalSince(last) < cooldown
    }

    private func markNotified(key: String) {
        lastNotified[key] = Date()
    }

    // MARK: - Local Notification Delivery

    private func send(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notify] ❌ Failed to deliver: \(error)")
            }
        }
    }
}
