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
}

enum NearifyContactsError: Error {
    case permissionDenied
}

actor NearifyContactsIndexService {
    static let shared = NearifyContactsIndexService()

    private let store = CNContactStore()
    private let contactSync = ContactSyncService.shared
    private var cachedResults: [NearifyContactSearchResult] = []

    func loadNearifyContacts() async throws -> [NearifyContactSearchResult] {
        guard await contactSync.requestAccessIfNeeded() else {
            throw NearifyContactsError.permissionDenied
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]

        var results: [NearifyContactSearchResult] = []
        let request = CNContactFetchRequest(keysToFetch: keys)

        try store.enumerateContacts(with: request) { contact, _ in
            guard contactSync.hasNearifyTag(contact: contact) else { return }
            let displayName = [contact.givenName, contact.familyName]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let eventName = extractNearifyEventName(from: contact.note)
            let eventDate = extractNearifyEventDate(from: contact.note)
            let contextSummary = extractNearifyContext(from: contact.note)
            let followUp = extractNearifyFollowUp(from: contact.note)

            results.append(
                NearifyContactSearchResult(
                    displayName: displayName.isEmpty ? "Unknown Contact" : displayName,
                    profileID: contactSync.extractNearifyProfileID(contact: contact),
                    phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                    emailAddresses: contact.emailAddresses.map { String($0.value) },
                    eventName: eventName,
                    eventDate: eventDate,
                    contextSummary: contextSummary,
                    followUp: followUp,
                    organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
                    sourceContactIdentifier: contact.identifier,
                    isNearifyEnhanced: true
                )
            )
        }

        let sorted = results.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        cachedResults = sorted
        return sorted
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

    private func extractNearifyEventName(from note: String) -> String? {
        extractNearifyField(from: note, fieldNames: ["Met at"])
    }

    private func extractNearifyEventDate(from note: String) -> String? {
        extractNearifyField(from: note, fieldNames: ["Event date"])
    }

    private func extractNearifyContext(from note: String) -> String? {
        extractNearifyField(from: note, fieldNames: ["Context"]) ?? extractNearifyMultilineSection(from: note, section: "Context")
    }

    private func extractNearifyFollowUp(from note: String) -> String? {
        extractNearifyField(from: note, fieldNames: ["Follow up"]) ?? extractNearifyMultilineSection(from: note, section: "Follow up")
    }

    private func extractNearifyField(from note: String, fieldNames: [String]) -> String? {
        for rawLine in note.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for field in fieldNames {
                let prefix = "\(field):"
                if line.lowercased().hasPrefix(prefix.lowercased()) {
                    let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    private func extractNearifyMultilineSection(from note: String, section: String) -> String? {
        let lines = note.components(separatedBy: .newlines)
        guard let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "\(section.lowercased()):" }) else {
            return nil
        }
        var collected: [String] = []
        for line in lines.dropFirst(idx + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            if trimmed.contains(":") && !trimmed.lowercased().hasPrefix("http") { break }
            collected.append(trimmed)
        }
        let value = collected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
