import Foundation
import Contacts

struct NearifyContactSearchResult: Identifiable, Hashable {
    let displayName: String
    let profileID: UUID?
    let phoneNumbers: [String]
    let emailAddresses: [String]
    let eventName: String?
    let eventDate: String?
    let contextSummary: String?
    let followUp: String?
    let organizationName: String?
    let sourceContactIdentifier: String
    let isNearifyEnhanced: Bool

    var id: String { sourceContactIdentifier }

    var hasContactIdentityFields: Bool {
        !displayName.isEmpty || (organizationName?.isEmpty == false)
    }
}

enum NearifyContactsError: Error {
    case permissionDenied
    case loadFailed
}

actor NearifyContactsIndexService {
    static let shared = NearifyContactsIndexService()

    private let store = CNContactStore()
    private let contactSync = ContactSyncService.shared
    private var cachedResults: [NearifyContactSearchResult] = []

    func loadNearifyContacts() async throws -> [NearifyContactSearchResult] {
        // Do not trigger Apple's contact-selection/share flow from the People entry point.
        // Nearify Contacts should only read already-granted permissions.
        let status = CNContactStore.authorizationStatus(for: .contacts)

        let canReadContacts: Bool
        if status == .authorized {
            canReadContacts = true
        } else if #available(iOS 18.0, *), status == .limited {
            canReadContacts = true
        } else {
            canReadContacts = false
        }

        guard canReadContacts else {
            throw NearifyContactsError.permissionDenied
        }

        do {
            let results = try fetchNearifyContacts(includeNoteKey: false)
            let sorted = results.sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            cachedResults = sorted
            return sorted
        } catch {
            if isUnauthorizedKeysError(error) {
                do {
                    let fallback = try fetchNearifyContacts(includeNoteKey: false)
                    let sorted = fallback.sorted { lhs, rhs in
                        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                    cachedResults = sorted
                    return sorted
                } catch {
                    throw NearifyContactsError.loadFailed
                }
            }
            throw NearifyContactsError.loadFailed
        }

    }


    private func fetchNearifyContacts(includeNoteKey: Bool) throws -> [NearifyContactSearchResult] {
        var keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]
        if includeNoteKey {
            keys.append(CNContactNoteKey as CNKeyDescriptor)
        }

        var results: [NearifyContactSearchResult] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, _ in
            guard contactSync.hasNearifyTag(contact: contact) else { return }
            let displayName = [contact.givenName, contact.familyName]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phoneNumbers = contact.phoneNumbers
                .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let emailAddresses = contact.emailAddresses
                .map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let organizationName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(
                NearifyContactSearchResult(
                    displayName: displayName,
                    profileID: contactSync.extractNearifyProfileID(contact: contact),
                    phoneNumbers: phoneNumbers,
                    emailAddresses: emailAddresses,
                    eventName: nil,
                    eventDate: nil,
                    contextSummary: nil,
                    followUp: nil,
                    organizationName: organizationName.isEmpty ? nil : organizationName,
                    sourceContactIdentifier: contact.identifier,
                    isNearifyEnhanced: true
                )
            )
        }
        return results
    }

    private func isUnauthorizedKeysError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CNErrorDomain && nsError.code == 102
    }

    func searchNearifyContacts(query: String) async throws -> [NearifyContactSearchResult] {
        let source = cachedResults.isEmpty ? try await loadNearifyContacts() : cachedResults
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }

        let normalizedQuery = trimmed.lowercased()

        return source
            .compactMap { result -> (NearifyContactSearchResult, Int)? in
                let name = result.displayName.lowercased()
                let organization = result.organizationName?.lowercased() ?? ""
                let event = result.eventName?.lowercased() ?? ""
                let context = result.contextSummary?.lowercased() ?? ""
                let followUp = result.followUp?.lowercased() ?? ""
                let emails = result.emailAddresses.joined(separator: " ").lowercased()
                let phones = result.phoneNumbers.joined(separator: " ").lowercased()
                let profile = result.profileID?.uuidString.lowercased() ?? ""

                if name == normalizedQuery { return (result, 0) }
                if name.hasPrefix(normalizedQuery) { return (result, 1) }
                if event.contains(normalizedQuery) || context.contains(normalizedQuery) || followUp.contains(normalizedQuery) { return (result, 2) }
                if organization.contains(normalizedQuery) { return (result, 3) }

                let haystack = [name, organization, event, context, followUp, emails, phones, profile].joined(separator: " ")
                if haystack.contains(normalizedQuery) { return (result, 4) }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
                }
                return lhs.1 < rhs.1
            }
            .map(\.0)
    }

}
