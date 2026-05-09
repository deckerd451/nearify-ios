import SwiftUI

struct NearifyContactDetailView: View {
    let contact: NearifyContactSearchResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Contact") {
                Text(contact.displayName)
                if let organization = contact.organizationName, !organization.isEmpty {
                    Text(organization).foregroundColor(.secondary)
                }
            }

            if contact.eventName != nil || contact.eventDate != nil || contact.contextSummary != nil || contact.followUp != nil {
                Section("Nearify Context") {
                    if let eventName = contact.eventName { row("Event", eventName) }
                    if let eventDate = contact.eventDate { row("Event date", eventDate) }
                    if let context = contact.contextSummary { row("Context", context) }
                    if let followUp = contact.followUp { row("Follow up", followUp) }
                }
            }

            if !contact.phoneNumbers.isEmpty {
                Section("Phone") {
                    ForEach(contact.phoneNumbers, id: \.self) { Text($0) }
                }
            }

            if !contact.emailAddresses.isEmpty {
                Section("Email") {
                    ForEach(contact.emailAddresses, id: \.self) { Text($0) }
                }
            }

            if let profileID = contact.profileID {
                Section {
                    Button("Open in Nearify") {
                        NavigationState.shared.peopleFocusTarget = PeopleFocusTarget(
                            profileId: profileID,
                            source: "nearifyContactDetail"
                        )
                        dismiss()

                    }
                }
            }
        }
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value)
        }
    }
}
