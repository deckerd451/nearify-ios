import Foundation
import CoreImage.CIFilterBuiltins
import UIKit

struct QRService {

    private static let nearifyBaseURL = URL(string: "https://nearify.org")!

    // MARK: - QR Generation

    /// Generates a QR code image from an arbitrary payload string.
    /// Displayed QR payloads should use browser-readable HTTPS URLs.
    static func generateQRCode(from payload: String) -> UIImage {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return UIImage(systemName: "xmark.circle") ?? UIImage()
        }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return UIImage(systemName: "xmark.circle") ?? UIImage()
        }

        return UIImage(cgImage: cgImage)
    }

    /// Legacy helper used by internal app flows.
    /// Format: beacon://profile/<community-id>
    static func generateQRCode(for communityId: String) -> UIImage {
        generateQRCode(from: "beacon://profile/\(communityId)")
    }

    /// Browser-readable event join URL used for displayed event QR payloads.
    static func makeEventJoinWebURL(eventId: UUID, eventName: String?) -> URL {
        var components = URLComponents(url: nearifyBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/join/"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "event", value: eventId.uuidString)
        ]

        if let eventName {
            let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                queryItems.append(URLQueryItem(name: "name", value: trimmed))
            }
        }

        components.queryItems = queryItems
        return components.url!
    }

    /// Browser-readable personal connect URL used for displayed personal QR payloads.
    static func makePersonalConnectWebURL(eventId: UUID, profileId: UUID) -> URL {
        var components = URLComponents(url: nearifyBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/join/"
        components.queryItems = [
            URLQueryItem(name: "event", value: eventId.uuidString),
            URLQueryItem(name: "profile", value: profileId.uuidString)
        ]
        return components.url!
    }

    // MARK: - Parsing

    enum QRPayload: Equatable {
        case profile(communityId: String)
        case event(eventId: String)
        case personalConnect(eventId: String, profileId: String)
    }

    /// Parses a scanned QR string into a typed payload.
    ///
    /// Supported formats:
    /// - beacon://event/<event-id>
    /// - beacon://profile/<community-id>
    /// - https://nearify.org/join/?event=<event-id>&name=<event-name>
    /// - https://nearify.org/join/?event=<event-id>&profile=<profile-id>
    /// - raw UUID (legacy profile format)
    static func parse(from qrString: String) -> QRPayload? {
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        #if DEBUG
        print("[QRService] Parsing QR: \(trimmed)")
        #endif

        if let payload = parseBeaconRoute(trimmed) {
            return payload
        }

        if let payload = parseNearifyJoinURL(trimmed) {
            return payload
        }

        if UUID(uuidString: trimmed) != nil {
            #if DEBUG
            print("[QRService] ✅ Parsed legacy raw UUID as profile")
            #endif
            return .profile(communityId: trimmed)
        }

        #if DEBUG
        print("[QRService] ❌ Unsupported QR format")
        #endif
        return nil
    }

    /// Legacy convenience — returns community ID string or nil.
    static func parseCommunityId(from qrString: String) -> String? {
        guard case .profile(let id) = parse(from: qrString) else { return nil }
        return id
    }

    // MARK: - Private Helpers

    private static func parseBeaconRoute(_ value: String) -> QRPayload? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "beacon" else {
            return nil
        }

        let host = components.host?.lowercased()
        let pathComponents = components.path
            .split(separator: "/")
            .map(String.init)

        if host == "event" {
            let eventId = pathComponents.first ?? ""
            guard UUID(uuidString: eventId) != nil else {
                #if DEBUG
                print("[QRService] ❌ Invalid beacon event UUID")
                #endif
                return nil
            }

            #if DEBUG
            print("[QRService] ✅ Parsed beacon event route")
            #endif
            return .event(eventId: eventId)
        }

        if host == "profile" {
            let communityId = pathComponents.first ?? ""
            guard UUID(uuidString: communityId) != nil else {
                #if DEBUG
                print("[QRService] ❌ Invalid beacon profile UUID")
                #endif
                return nil
            }

            #if DEBUG
            print("[QRService] ✅ Parsed beacon profile route")
            #endif
            return .profile(communityId: communityId)
        }

        return nil
    }

    private static func parseNearifyJoinURL(_ value: String) -> QRPayload? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased() else {
            return nil
        }

        let allowedHosts = [
            "nearify.org",
            "www.nearify.org"
        ]

        guard allowedHosts.contains(host) else {
            return nil
        }

        let normalizedPath = components.path.lowercased()
        guard normalizedPath == "/join" || normalizedPath == "/join/" else {
            return nil
        }

        guard let eventId = components.queryItems?
            .first(where: { $0.name == "event" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: eventId) != nil else {
            #if DEBUG
            print("[QRService] ❌ nearify join URL missing valid event param")
            #endif
            return nil
        }

        let profileId = components.queryItems?
            .first(where: { $0.name == "profile" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let profileId, UUID(uuidString: profileId) != nil {
            #if DEBUG
            print("[QRService] ✅ Parsed nearify personal connect URL")
            #endif
            return .personalConnect(eventId: eventId, profileId: profileId)
        }

        #if DEBUG
        print("[QRService] ✅ Parsed nearify event join URL")
        #endif
        return .event(eventId: eventId)
    }
}
