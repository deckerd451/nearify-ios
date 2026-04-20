import Foundation
import UserNotifications

/// Intelligent local notification system for Nearify.
/// Aligned with the time-aware priority model used by the Home surface.
/// Only high-urgency CONTINUE or truly IMMEDIATE/LIVE items trigger notifications.
/// INSIGHTS generally do NOT trigger push notifications.
/// NEXT MOVES only notify when timing is truly important.
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

    // MARK: - Thresholds (aligned with temporal model)

    private enum Threshold {
        static let encounterOverlapSeconds: Int = 120   // 2 min minimum to notify
        static let intelligenceScore: Double = 50       // minimum ranked score to notify
        // Temporal: only IMMEDIATE or LIVE items are notification-eligible
        static let maxNotificationAge: TimeInterval = 900  // 15 min — beyond this, no push
    }

    // MARK: - State

    /// Tracks last notification time per dedupe key (type:profileId).
    private var lastNotified: [String: Date] = [:]

    /// Conversation currently being viewed (suppress redundant system notifications).
    var activeConversationId: UUID?

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

    /// Evaluate feed items after a refresh. Message notifications are handled by MessageNotificationCoordinator.
    func evaluateFeedItems(_ items: [FeedItem]) {
        _ = items
    }

    /// Evaluate event intelligence results. Only notify for high-urgency decisions.
    /// INSIGHTS are suppressed from push notifications.
    /// Only CONTINUE-eligible items (Tier 1-2) trigger notifications.
    func evaluateEventIntelligence(_ profiles: [RankedProfile]) {
        for profile in profiles {
            guard let decision = profile.decision else { continue }
            guard !profile.isConnected else { continue }

            // Only notify for high-urgency tiers (active conversation, strong interaction)
            // This aligns with CONTINUE section eligibility
            guard decision.tier == .activeConversation || decision.tier == .strongInteraction else {
                #if DEBUG
                print("[Notify] Intel skip (tier too low for push): \(profile.name) tier=\(decision.tier.rawValue)")
                #endif
                continue
            }

            // Temporal gate: only notify if interaction is recent
            if let lastAt = profile.lastInteractionAt {
                let age = Date().timeIntervalSince(lastAt)
                guard age < Threshold.maxNotificationAge else {
                    #if DEBUG
                    print("[Notify] Intel skip (stale): \(profile.name) age=\(Int(age))s")
                    #endif
                    continue
                }
            }

            let key = "intelligence:\(profile.profileId)"
            guard !isCoolingDown(key: key, cooldown: Cooldown.intelligence) else {
                #if DEBUG
                print("[Notify] Intel skip (cooldown): \(profile.name)")
                #endif
                continue
            }

            markNotified(key: key)

            // Use action-oriented language matching the Home surface
            let body: String
            switch decision.tier {
            case .activeConversation:
                body = "\(profile.name) — keep the conversation going"
            case .strongInteraction:
                body = "\(profile.name) is nearby — go say hi"
            default:
                body = decision.reason
            }

            send(
                title: decision.tier == .activeConversation ? "Continue" : "Nearby",
                body: body,
                identifier: key
            )

            #if DEBUG
            print("[Notify] Intel triggered: \(profile.name) tier=\(decision.tier.rawValue)")
            #endif
        }
    }

    /// Sends one deterministic local notification for a message when app is not active.
    func sendMessageNotification(messageId: UUID, fromName: String, preview: String?) {
        let key = "message:\(messageId)"

        let firstName = fromName.components(separatedBy: " ").first ?? fromName
        let body: String
        if let preview, !preview.isEmpty {
            body = "Reply to \(firstName) — \(String(preview.prefix(60)))"
        } else {
            body = "Reply to \(firstName)"
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
    /// Only notifies for IMMEDIATE/LIVE temporal states with sufficient overlap.
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

        // Action-oriented: "Find Doug — you've been nearby"
        let firstName = (profileName ?? "someone").components(separatedBy: " ").first ?? "someone"
        send(
            title: "Someone nearby",
            body: "Find \(firstName) — you've been nearby",
            identifier: key
        )

        #if DEBUG
        print("[Notify] Encounter triggered: \(firstName) (\(overlapSeconds)s)")
        #endif
    }

    /// Called after a new connection is created.
    func onConnectionCreated(profileId: UUID, profileName: String?) {
        let key = "connection:\(profileId)"
        guard !isCoolingDown(key: key, cooldown: Cooldown.connection) else { return }

        markNotified(key: key)

        let firstName = (profileName ?? "someone").components(separatedBy: " ").first ?? "someone"
        send(
            title: "New connection",
            body: "You connected with \(firstName)",
            identifier: key
        )

        #if DEBUG
        print("[Notify] Connection triggered: \(firstName)")
        #endif
    }

    /// Clears all cooldown state (e.g., when leaving an event).
    func reset() {
        lastNotified.removeAll()
        activeConversationId = nil
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
