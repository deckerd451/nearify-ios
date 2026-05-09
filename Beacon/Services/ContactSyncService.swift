import Foundation
import Contacts

actor ContactSyncState {
    private var inFlightKeys: Set<String> = []
    private var permissionCache: Bool?
    private var didRequestPermission = false

    func insert(_ key: String) -> Bool {
        if inFlightKeys.contains(key) {
            return false
        }
        inFlightKeys.insert(key)
        return true
    }

    func remove(_ key: String) {
        inFlightKeys.remove(key)
    }

    func canRequestPermission() -> Bool {
        if permissionCache != nil {
            return false
        }
        if didRequestPermission {
            return false
        }
        didRequestPermission = true
        return true
    }

    func cachedPermission() -> Bool? {
        permissionCache
    }

    func setPermission(_ granted: Bool) {
        permissionCache = granted
    }
}

struct ContactSyncPayload {
    let profileId: UUID
    let name: String
    let phoneNumber: String?
    let email: String?

    let eventId: UUID
    let eventName: String
    let eventDate: Date

    let interactionSummary: String

    // Preserve EL intelligence
    let signalScore: Double
    let interactionCount: Int
    let intentAlignment: Double
}

struct NearifyContactMetadata {
    let profileID: UUID?
    let isNearifyEnhanced: Bool
}

final class ContactSyncService {
    static let shared = ContactSyncService()

    private let defaults = UserDefaults.standard
    private let idempotencyPrefix = "contactsync.processed"
    private let contactIdentifierPrefix = "contactsync.contactid"
    private let state = ContactSyncState()

    private init() {}

    private func dedupeKey(profileId: UUID, eventId: UUID) -> String {
        "\(profileId.uuidString.lowercased())_\(eventId.uuidString.lowercased())"
    }

    private func persistedKey(for dedupeKey: String) -> String {
        "\(idempotencyPrefix).\(dedupeKey)"
    }

    private func persistedContactIdentifierKey(profileId: UUID) -> String {
        "\(contactIdentifierPrefix).\(profileId.uuidString.lowercased())"
    }

    // MARK: - Permission

    func requestAccessIfNeeded() async -> Bool {
        if let cached = await state.cachedPermission() {
            return cached
        }
        guard await state.canRequestPermission() else {
            return false
        }

        let store = CNContactStore()

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            await state.setPermission(true)
            return true

        case .limited:
            // Limited access is sufficient for creating/updating contacts
            await state.setPermission(true)
            return true

        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error = error {
                        print("[ContactSync] Permission request error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            }
            await state.setPermission(granted)
            return granted

        case .denied, .restricted:
            await state.setPermission(false)
            print("[ContactSync] Permission denied or restricted")
            return false

        @unknown default:
            await state.setPermission(false)
            return false
        }
    }

    // MARK: - Idempotency

    func shouldCreateContact(profileId: UUID, eventId: UUID) async -> Bool {
        let key = dedupeKey(profileId: profileId, eventId: eventId)
        let persistedKey = persistedKey(for: key)

        if defaults.bool(forKey: persistedKey) {
            return false
        }

        let didInsert = await state.insert(key)
        guard didInsert else {
            print("[ContactSync] Skipped duplicate for \(key)")
            return false
        }

        return true
    }

    func hasSavedContact(profileId: UUID, eventId: UUID) -> Bool {
        let key = dedupeKey(profileId: profileId, eventId: eventId)
        return defaults.bool(forKey: persistedKey(for: key))
    }

    // MARK: - Nearify Metadata Helpers

    func buildNearifyNotesBlock(from payload: ContactSyncPayload) -> String {
        let trimmedEventName = payload.eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = payload.interactionSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "[Nearify]",
            "Saved via Nearify"
        ]

        if !trimmedEventName.isEmpty {
            lines.append("")
            lines.append("Met at: \(trimmedEventName)")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            lines.append("Event date: \(formatter.string(from: payload.eventDate))")
        }

        if !trimmedContext.isEmpty {
            lines.append("")
            lines.append("Context:")
            lines.append(trimmedContext)
        }

        if payload.signalScore >= 1.5 {
            lines.append("")
            lines.append("Follow up:")
            lines.append("High interaction signal — continue the conversation.")
        }

        lines.append("")
        lines.append("NearifyID: \(payload.profileId.uuidString.lowercased())")
        return lines.joined(separator: "\n")
    }

    func upsertNearifyNotesBlock(existingNotes: String, metadataBlock: String) -> String {
        let pattern = #"(?s)(?:\n{2,})?\[Nearify\]\n.*?(?=(?:\n{2,}\[Nearify\]\n)|\z)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(existingNotes.startIndex..<existingNotes.endIndex, in: existingNotes)
        let cleaned = regex?.stringByReplacingMatches(in: existingNotes, options: [], range: range, withTemplate: "")
            ?? existingNotes
        let preserved = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if preserved.isEmpty { return metadataBlock }
        return preserved + "\n\n" + metadataBlock
    }

    func hasNearifyTag(contact: CNContact) -> Bool {
        let note = contact.note
        if note.contains("[Nearify]") || note.contains("NearifyID:") {
            return true
        }
        return contact.urlAddresses.contains {
            String($0.value).lowercased().hasPrefix("nearify://profile/")
        }
    }

    func extractNearifyProfileID(contact: CNContact) -> UUID? {
        if let urlValue = contact.urlAddresses.first(where: {
            String($0.value).lowercased().hasPrefix("nearify://profile/")
        }) {
            let raw = String(urlValue.value)
            let prefix = "nearify://profile/"
            let suffix = raw.lowercased().hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
            if let id = UUID(uuidString: suffix.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return id
            }
        }

        let pattern = #"NearifyID:\s*([0-9a-fA-F-]{36})"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(contact.note.startIndex..<contact.note.endIndex, in: contact.note)
            if let match = regex.firstMatch(in: contact.note, options: [], range: range),
               let idRange = Range(match.range(at: 1), in: contact.note) {
                return UUID(uuidString: String(contact.note[idRange]))
            }
        }
        return nil
    }

    func inspectMetadata(contact: CNContact) -> NearifyContactMetadata {
        let profileID = extractNearifyProfileID(contact: contact)
        return NearifyContactMetadata(profileID: profileID, isNearifyEnhanced: hasNearifyTag(contact: contact))
    }

    // MARK: - Write

    @discardableResult
    func createOrUpdateContact(payload: ContactSyncPayload) async -> Bool {
        let key = dedupeKey(profileId: payload.profileId, eventId: payload.eventId)
        let persistedKey = persistedKey(for: key)

        guard await shouldCreateContact(profileId: payload.profileId, eventId: payload.eventId) else {
            print("[ContactSync] Skipped duplicate for event")
            return false
        }

        guard await requestAccessIfNeeded() else {
            await state.remove(key)
            print("[ContactSync] Permission denied")
            return false
        }

        let nearifyBlock = buildNearifyNotesBlock(from: payload)
        let didSave = await Task.detached(priority: .utility) { () -> Bool in
            do {
                let store = CNContactStore()
                let saveRequest = CNSaveRequest()

                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactNoteKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor
                ]

                var existing: CNMutableContact?
                let identifierKey = self.persistedContactIdentifierKey(profileId: payload.profileId)
                let existingIdentifier = self.defaults.string(forKey: identifierKey)

                if let existingIdentifier, !existingIdentifier.isEmpty {
                    do {
                        let contact = try store.unifiedContact(withIdentifier: existingIdentifier, keysToFetch: keys)
                        existing = contact.mutableCopy() as? CNMutableContact
                    } catch {
                        existing = nil
                    }
                }

                if let existing {
                    existing.note = self.upsertNearifyNotesBlock(existingNotes: existing.note, metadataBlock: nearifyBlock)
                    self.upsertNearifyURL(contact: existing, profileID: payload.profileId)
                    saveRequest.update(existing)
                    try store.execute(saveRequest)
#if DEBUG
                    print("[ContactSync] Updated existing contact")
#endif
                    self.defaults.set(existing.identifier, forKey: identifierKey)
                    return true
                }

                let newContact = CNMutableContact()
                let parts = payload.name
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)

                if let first = parts.first {
                    newContact.givenName = first
                }
                if parts.count > 1 {
                    newContact.familyName = parts.dropFirst().joined(separator: " ")
                }
                if newContact.givenName.isEmpty {
                    newContact.givenName = payload.name
                }

                if let phone = payload.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
                    let labeled = CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
                    newContact.phoneNumbers = [labeled]
                }

                if let email = payload.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                    let labeled = CNLabeledValue(label: CNLabelWork, value: email as NSString)
                    newContact.emailAddresses = [labeled]
                }

                newContact.note = self.upsertNearifyNotesBlock(existingNotes: newContact.note, metadataBlock: nearifyBlock)
                self.upsertNearifyURL(contact: newContact, profileID: payload.profileId)

                let containerId = store.defaultContainerIdentifier()
                saveRequest.add(newContact, toContainerWithIdentifier: containerId)
                try store.execute(saveRequest)
#if DEBUG
                print("[ContactSync] Created contact")
#endif
                self.defaults.set(newContact.identifier, forKey: identifierKey)
                return true
            } catch {
                print("[ContactSync] Save failed: \(error.localizedDescription)")
                return false
            }
        }.value

        if didSave {
            defaults.set(true, forKey: persistedKey)
            await state.remove(key)
            return true
        }

        await state.remove(key)
        return false
    }

    func upsertNearifyURL(contact: CNMutableContact, profileID: UUID?) {
        guard let profileID else { return }
        let target = "nearify://profile/\(profileID.uuidString.lowercased())"
        let alreadyPresent = contact.urlAddresses.contains {
            String($0.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
        guard !alreadyPresent else { return }

        var urls = contact.urlAddresses
        urls.append(CNLabeledValue(label: "Nearify", value: target as NSString))
        contact.urlAddresses = urls
    }
}
