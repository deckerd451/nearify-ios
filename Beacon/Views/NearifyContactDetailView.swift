import SwiftUI

struct NearifyContactDetailView: View {
    let contact: NearifyContactSearchResult
    @State private var isRoutingToPeople = false

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
                        guard let profileID = contact.profileID, !isRoutingToPeople else { return }
                        isRoutingToPeople = true
                        #if DEBUG
                        let shortId = String(profileID.uuidString.prefix(8))
                        print("[NearifyContacts] Open in Nearify tapped profile=\(shortId)")
                        #endif
                        #if DEBUG
                        print("[PeopleNav] Open in Nearify start; requesting path reset + tab route")
                        #endif
                        NavigationState.shared.requestPeopleSubroutePopToRoot()
                        NavigationState.shared.requestGlobalTabRoute(to: .people)
                        DispatchQueue.main.async {
                            #if DEBUG
                            print("[PeopleNav] assigning focus target on next main cycle")
                            #endif
                            NavigationState.shared.peopleFocusTarget = PeopleFocusTarget(
                                profileId: profileID,
                                source: "nearifyContactDetail"
                            )
                            #if DEBUG
                            print("[Navigation] peopleFocusTarget set from Nearify Contacts")
                            #endif
                            isRoutingToPeople = false
                        }

                    }
                    .disabled(isRoutingToPeople)
                }
            }
        }
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            #if DEBUG
            print("[PeopleNav] NearifyContactDetailView unmounted")
            #endif
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value)
        }
    }
}
