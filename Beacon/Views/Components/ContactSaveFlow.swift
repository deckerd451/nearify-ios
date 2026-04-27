import SwiftUI
import Contacts
import ContactsUI

struct ContactDraftData {
    let name: String
    let nearifyProfileIdentifier: UUID?
    let eventName: String?
    let imageData: Data?
    let phoneNumbers: [String]
    let emailAddresses: [String]
    let linkedInUrl: String?
    let socialProfiles: [(label: String?, username: String, service: String, urlString: String?)]
    let interactionLine: String?
    let memoryCues: [String]
    let followUpLine: String?

    var nearifyIdentityURL: URL? {
        guard let nearifyProfileIdentifier else { return nil }
        return URL(string: "nearify://profile/\(nearifyProfileIdentifier.uuidString.lowercased())")
    }

    private var contextBulletLines: [String] {
        var lines: [String] = []

        if let interactionLine, !interactionLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("• \(interactionLine)")
        }

        if !memoryCues.isEmpty {
            lines.append("• \(memoryCues.prefix(2).joined(separator: " · "))")
        }

        if let followUpLine, !followUpLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("• \(followUpLine)")
        }

        return lines
    }

    private var nearifyIdentifierFallbackLine: String? {
        guard let nearifyProfileIdentifier else { return nil }
        return "NearifyID: \(nearifyProfileIdentifier.uuidString.lowercased())"
    }

    var note: String {
        let normalizedEvent = eventName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventLine = "Met at \((normalizedEvent?.isEmpty == false) ? normalizedEvent! : "a Nearify event")\nvia Nearify"

        var sections: [String] = [eventLine]
        if !contextBulletLines.isEmpty {
            sections.append(contextBulletLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    var mutableContact: CNMutableContact {
        let contact = CNMutableContact()
        let parts = name
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        if let first = parts.first {
            contact.givenName = first
        }
        if parts.count > 1 {
            contact.familyName = parts.dropFirst().joined(separator: " ")
        }
        if contact.givenName.isEmpty {
            contact.givenName = name
        }

        if let imageData, !imageData.isEmpty {
            contact.imageData = imageData
        }

        let validPhones = phoneNumbers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !validPhones.isEmpty {
            contact.phoneNumbers = validPhones.map {
                CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
            }
        }

        let validEmails = emailAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !validEmails.isEmpty {
            contact.emailAddresses = validEmails.map {
                CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
            }
        }

        var builtSocialProfiles: [CNLabeledValue<CNSocialProfile>] = []
        if let linkedInUrl,
           let profile = Self.makeSocialProfile(username: nil, service: CNSocialProfileServiceLinkedIn, urlString: linkedInUrl) {
            builtSocialProfiles.append(CNLabeledValue(label: CNLabelURLAddressHomePage, value: profile))
        }

        for social in socialProfiles {
            if let profile = Self.makeSocialProfile(
                username: social.username,
                service: social.service,
                urlString: social.urlString
            ) {
                builtSocialProfiles.append(CNLabeledValue(label: social.label, value: profile))
            }
        }

        if !builtSocialProfiles.isEmpty {
            contact.socialProfiles = builtSocialProfiles
        }

        let supportsURLFieldInCurrentFlow = true
        if supportsURLFieldInCurrentFlow, let nearifyIdentityURL {
            let existingURLs = contact.urlAddresses
            let nearifyURL = CNLabeledValue(label: "Nearify", value: nearifyIdentityURL as NSURL)
            contact.urlAddresses = existingURLs + [nearifyURL]
            contact.note = note
        } else {
            if let fallbackLine = nearifyIdentifierFallbackLine {
                contact.note = [note, fallbackLine].joined(separator: "\n\n")
            } else {
                contact.note = note
            }
        }

        return contact
    }

    private static func makeSocialProfile(username: String?, service: String, urlString: String?) -> CNSocialProfile? {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedUsername?.isEmpty == false) || (trimmedURL?.isEmpty == false) else {
            return nil
        }

        return CNSocialProfile(
            urlString: trimmedURL,
            username: trimmedUsername,
            userIdentifier: nil,
            service: service
        )
    }
}

struct ContactSaveSheet: UIViewControllerRepresentable {
    let draft: ContactDraftData
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contactVC = CNContactViewController(forNewContact: draft.mutableContact)
        contactVC.delegate = context.coordinator
        contactVC.allowsActions = false
        contactVC.allowsEditing = true

        let nav = UINavigationController(rootViewController: contactVC)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        private let onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onComplete(contact != nil)
        }
    }
}
