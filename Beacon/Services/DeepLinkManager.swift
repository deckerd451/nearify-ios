import Foundation
import Combine

@MainActor
final class DeepLinkManager: ObservableObject {

    static let shared = DeepLinkManager()

    @Published private(set) var pendingEventId: String?
    @Published private(set) var pendingProfileId: UUID?

    private init() {}

    private func parseNearifyProfileId(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "nearify" else { return nil }
        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        let candidate: String?
        if host == "profile" {
            candidate = pathComponents.first
        } else if host == nil, pathComponents.count >= 2, pathComponents[0].lowercased() == "profile" {
            candidate = pathComponents[1]
        } else {
            candidate = nil
        }

        guard let raw = candidate, let profileId = UUID(uuidString: raw) else {
            #if DEBUG
            print("[DeepLink] ⚠️ Malformed nearify profile URL: \(url.absoluteString)")
            #endif
            return nil
        }
        return profileId
    }

    @discardableResult
    func handle(url: URL) -> Bool {
        let urlString = url.absoluteString

        #if DEBUG
        print("🚨 DeepLinkManager.handle called: \(urlString)")
        #endif

        if let profileId = parseNearifyProfileId(from: url) {
            pendingProfileId = profileId
            #if DEBUG
            print("[DeepLink] 👤 Stored pending Nearify profile: \(profileId.uuidString)")
            #endif
            return true
        }

        guard let payload = QRService.parse(from: urlString) else {
            #if DEBUG
            print("[DeepLink] ❓ Unrecognized URL: \(urlString)")
            #endif
            return false
        }

        switch payload {
        case .event(let eventId):
            pendingEventId = eventId
            #if DEBUG
            print("[DeepLink] 📥 Stored pending event: \(eventId)")
            #endif

        case .profile(let communityId):
            #if DEBUG
            print("[DeepLink] 👤 Profile URL received: \(communityId)")
            #endif

        case .personalConnect(let eventId, let profileId):
            #if DEBUG
            print("[DeepLink] 🤝 Personal connect URL received: event=\(eventId), profile=\(profileId)")
            #endif
        }

        return true
    }

    func consumeEventId() -> String? {
        guard let id = pendingEventId else {
            #if DEBUG
            print("[DeepLink] 📭 No pending event to consume")
            #endif
            return nil
        }

        pendingEventId = nil

        #if DEBUG
        print("[DeepLink] 📤 Consumed pending event: \(id)")
        #endif

        return id
    }

    func consumeProfileId() -> UUID? {
        guard let id = pendingProfileId else { return nil }
        pendingProfileId = nil
        return id
    }

    func clear() {
        #if DEBUG
        if let pendingEventId {
            print("[DeepLink] 🧹 Clearing pending event: \(pendingEventId)")
        }
        #endif
        pendingEventId = nil
        pendingProfileId = nil
    }
}
