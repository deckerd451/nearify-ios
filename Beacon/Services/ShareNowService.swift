import UIKit

/// Dual-mode share service for the Say Goodbye flow.
///
/// Builds a shareable artifact that works in two layers:
/// - Layer 1 (Primary): vCard contact — works without Nearify installed
/// - Layer 2 (Secondary): Nearify deep link + install URL
///
/// Uses the native iOS share sheet (AirDrop, Messages, Mail, etc.).
///
/// This service:
/// - Uses `AppEnvironment.nearifyShareInstallURL` as the single source of truth for install destination
/// - Does NOT create interaction_events or connection edges
/// - Does NOT modify any app state on success or failure
/// - Does NOT depend on AirDrop specifically — any share method works
/// - Does NOT require the receiver to have Nearify
@MainActor
enum ShareNowService {

    /// Result of a share sheet interaction.
    enum ShareResult {
        case completed(activityType: String)  // User completed sharing via a specific method
        case cancelled                         // User dismissed the share sheet
        case failed(String)                    // Share sheet encountered an error
    }

    // MARK: - Share

    /// Presents the system share sheet with a dual-mode contact artifact.
    /// Returns true if the share sheet was presented, false if unavailable.
    @discardableResult
    static func presentShareSheet() -> Bool {
        return presentShareSheet(completion: nil)
    }

    /// Presents the system share sheet with a completion callback reporting the outcome.
    /// Returns true if the share sheet was presented, false if unavailable.
    @discardableResult
    static func presentShareSheet(completion: ((ShareResult) -> Void)?) -> Bool {
        guard let user = AuthService.shared.currentUser else {
            #if DEBUG
            print("[ShareNow] ⚠️ No current user — cannot share")
            #endif
            return false
        }

        let deepLink = URL(string: "beacon://profile/\(user.id.uuidString)")!
        let installURL = AppEnvironment.nearifyShareInstallURL

        #if DEBUG
        print("[ShareNow] preparing share for \(user.name)")
        print("[ShareNow] using install URL: \(installURL.absoluteString)")
        #endif

        // Build share items: vCard (primary) + text fallback
        var items: [Any] = []

        // Layer 1: vCard — universally useful as a contact card
        if let vcardData = buildVCard(user: user, deepLink: deepLink, installURL: installURL) {
            let tempURL = writeVCardToTemp(data: vcardData, name: user.name)
            if let tempURL {
                items.append(tempURL)
            }
        }

        // Layer 2: Text fallback — always included for share methods that don't handle files
        let shareText = buildShareText(user: user, deepLink: deepLink, installURL: installURL)
        items.append(shareText)

        guard !items.isEmpty else {
            #if DEBUG
            print("[ShareNow] ⚠️ No share items built")
            #endif
            return false
        }

        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        // Exclude noisy activity types
        activityVC.excludedActivityTypes = [
            .addToReadingList,
            .openInIBooks,
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .postToFlickr,
            .postToVimeo,
            .postToTencentWeibo,
            .print
        ]

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            #if DEBUG
            print("[ShareNow] ⚠️ No root view controller")
            #endif
            return false
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }

        activityVC.completionWithItemsHandler = { activityType, completed, _, error in
            let activityName = Self.friendlyActivityName(activityType)

            if completed {
                print("[ShareNow] share completed via \(activityName)")
                print("[ShareNow] no receiver-side confirmation available — sender-side only")
                Task { @MainActor in
                    completion?(.completed(activityType: activityName))
                }
            } else if let error {
                print("[ShareNow] share failed: \(error.localizedDescription)")
                Task { @MainActor in
                    completion?(.failed(error.localizedDescription))
                }
            } else {
                print("[ShareNow] share sheet cancelled")
                Task { @MainActor in
                    completion?(.cancelled)
                }
            }
        }

        topVC.present(activityVC, animated: true)

        #if DEBUG
        print("[ShareNow] presenting share sheet")
        #endif

        return true
    }

    // MARK: - Activity Name Resolution

    /// Maps UIActivity type identifiers to human-readable names for logging.
    private static func friendlyActivityName(_ activityType: UIActivity.ActivityType?) -> String {
        guard let raw = activityType?.rawValue else { return "unknown" }
        switch raw {
        case "com.apple.UIKit.activity.AirDrop":           return "AirDrop"
        case "com.apple.UIKit.activity.Message":           return "Messages"
        case "com.apple.UIKit.activity.Mail":              return "Mail"
        case "com.apple.UIKit.activity.CopyToPasteboard":  return "Copy"
        case let s where s.contains("slack"):              return "Slack"
        case let s where s.contains("whatsapp"):           return "WhatsApp"
        case let s where s.contains("telegram"):           return "Telegram"
        default:
            // Extract the last component for readability
            let parts = raw.components(separatedBy: ".")
            return parts.last ?? raw
        }
    }

    // MARK: - vCard Builder

    /// Builds a vCard (VCF) string for the current user.
    /// Includes name, bio as note, Nearify deep link as URL, and install link.
    private static func buildVCard(user: User, deepLink: URL, installURL: URL) -> Data? {
        var lines: [String] = []
        lines.append("BEGIN:VCARD")
        lines.append("VERSION:3.0")

        // Name
        let nameParts = user.name.components(separatedBy: " ")
        let firstName = nameParts.first ?? user.name
        let lastName = nameParts.count > 1 ? nameParts.dropFirst().joined(separator: " ") : ""
        lines.append("N:\(escapeVCard(lastName));\(escapeVCard(firstName));;;")
        lines.append("FN:\(escapeVCard(user.name))")

        // Organization — identifies the source
        lines.append("ORG:Nearify")

        // Bio as note (if available and safe)
        if let bio = user.bio, !bio.isEmpty {
            let trimmed = String(bio.prefix(200))
            lines.append("NOTE:\(escapeVCard(trimmed))")
        }

        // Nearify profile deep link
        lines.append("URL:\(deepLink.absoluteString)")

        // Install link as a second URL item with label
        lines.append("item1.URL:\(installURL.absoluteString)")
        lines.append("item1.X-ABLabel:Get Nearify")

        // Photo URL (if available) — some apps will fetch and display it
        if let imageUrl = user.imageUrl, !imageUrl.isEmpty {
            lines.append("PHOTO;VALUE=uri:\(imageUrl)")
        }

        lines.append("END:VCARD")

        let vcardString = lines.joined(separator: "\r\n")
        return vcardString.data(using: .utf8)
    }

    /// Escapes special characters for vCard format.
    private static func escapeVCard(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Writes vCard data to a temporary file for sharing.
    private static func writeVCardToTemp(data: Data, name: String) -> URL? {
        let sanitized = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let fileName = "\(sanitized)_Nearify.vcf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            #if DEBUG
            print("[ShareNow] ⚠️ Failed to write vCard: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Text Fallback

    /// Builds a human-readable text payload as fallback.
    private static func buildShareText(user: User, deepLink: URL, installURL: URL) -> String {
        var parts: [String] = []

        parts.append(user.name)

        if let bio = user.bio, !bio.isEmpty {
            parts.append(String(bio.prefix(100)))
        }

        parts.append("")
        parts.append("View on Nearify: \(deepLink.absoluteString)")
        parts.append("Get Nearify: \(installURL.absoluteString)")

        return parts.joined(separator: "\n")
    }
}
