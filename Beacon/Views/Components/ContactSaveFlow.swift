import SwiftUI
import Contacts
import ContactsUI

struct ContactDraftData {
    let name: String
    let eventName: String
    let interests: [String]
    let skills: [String]
    let earnedTraits: [String]

    var note: String {
        var lines: [String] = ["Met at \(eventName) via Nearify"]

        if !interests.isEmpty {
            lines.append("")
            lines.append("Interests: \(interests.joined(separator: ", "))")
        }

        if !skills.isEmpty {
            lines.append("Skills: \(skills.joined(separator: ", "))")
        }

        if !earnedTraits.isEmpty {
            lines.append("Earned traits: \(earnedTraits.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
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

        contact.note = note
        return contact
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
