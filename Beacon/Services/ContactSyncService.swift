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

    func hasSavedContact(profileId: UUID) -> Bool {
        let identifierKey = persistedContactIdentifierKey(profileId: profileId)
        guard let identifier = defaults.string(forKey: identifierKey), !identifier.isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Note Builder

    func buildNote(from payload: ContactSyncPayload) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "LLLL yyyy"

        let signalLabel: String
        if payload.signalScore >= 1.5 {
            signalLabel = "Strong"
        } else if payload.signalScore >= 0.5 {
            signalLabel = "Moderate"
        } else {
            signalLabel = "Light"
        }

        let context = payload.interactionSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        Met at \(payload.eventName) — \(formatter.string(from: payload.eventDate))

        Context:
        \(context.isEmpty ? "Meaningful interaction" : context)

        Signal:
        \(signalLabel) interaction signal

        Generated by Nearify
        """
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

        let newNote = buildNote(from: payload)
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
                    CNContactNoteKey as CNKeyDescriptor
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
                    if existing.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        existing.note = newNote
                    } else {
                        existing.note = existing.note + "\n\n---\n" + newNote
                    }
                    saveRequest.update(existing)
                    try store.execute(saveRequest)
                    print("[ContactSync] Updated existing contact")
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

                newContact.note = newNote

                let containerId = store.defaultContainerIdentifier()
                saveRequest.add(newContact, toContainerWithIdentifier: containerId)
                try store.execute(saveRequest)
                print("[ContactSync] Created contact for \(payload.name)")
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
}
