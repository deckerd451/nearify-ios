import Foundation

/// Tracks lightweight, per-event connection prompt state to prevent repeated prompts/haptics.
@MainActor
final class ConnectionPromptStateStore {
    static let shared = ConnectionPromptStateStore()

    private var shownKeys: Set<String> = []
    private var dismissedKeys: Set<String> = []
    private var savedKeys: Set<String> = []

    private init() {}

    func hasShown(profileId: UUID, eventId: String?) -> Bool {
        shownKeys.contains(key(profileId: profileId, eventId: eventId))
    }

    func isDismissed(profileId: UUID, eventId: String?) -> Bool {
        dismissedKeys.contains(key(profileId: profileId, eventId: eventId))
    }

    func isSaved(profileId: UUID, eventId: String?) -> Bool {
        savedKeys.contains(key(profileId: profileId, eventId: eventId))
    }

    func markShown(profileId: UUID, eventId: String?) {
        shownKeys.insert(key(profileId: profileId, eventId: eventId))
    }

    func markDismissed(profileId: UUID, eventId: String?) {
        dismissedKeys.insert(key(profileId: profileId, eventId: eventId))
    }

    func markSaved(profileId: UUID, eventId: String?) {
        savedKeys.insert(key(profileId: profileId, eventId: eventId))
    }

    private func key(profileId: UUID, eventId: String?) -> String {
        "\(eventId ?? "no-event"):\(profileId.uuidString.lowercased())"
    }
}
