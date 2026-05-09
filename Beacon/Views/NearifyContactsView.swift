import SwiftUI
import Contacts
import UIKit

struct NearifyContactsView: View {
    @State private var contacts: [NearifyContactSearchResult] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var permissionStatus = CNContactStore.authorizationStatus(for: .contacts)

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Nearify Contacts…")
                    .tint(.white)
                    .foregroundColor(.white)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Text("Enable Contact Access")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if contacts.isEmpty {
                ContentUnavailableView("No Nearify Contacts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Contacts tagged with Nearify metadata will appear here."))
            } else {
                List(contacts) { contact in
                    NavigationLink(destination: NearifyContactDetailView(contact: contact)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(contact.displayName).font(.headline)
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundColor(.blue.opacity(0.8))
                            }
                            if let org = contact.organizationName, !org.isEmpty {
                                Text(org).font(.subheadline).foregroundColor(.secondary)
                            }
                            if let event = contact.eventName {
                                Text("Event: \(event)").font(.caption).foregroundColor(.secondary)
                            }
                            if let preview = contact.contextSummary ?? contact.followUp {
                                Text(preview).font(.caption).lineLimit(2).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Nearify Contacts")
        .searchable(text: $query, prompt: "Search people, event, context")
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await refreshPermissionAndReload() }
        }
        .onChange(of: query) { _, _ in
            Task { await search() }
        }
    }

    private func reload() async {
        permissionStatus = CNContactStore.authorizationStatus(for: .contacts)
        isLoading = true
        defer { isLoading = false }
        do {
            contacts = try await NearifyContactsIndexService.shared.loadNearifyContacts()
            errorMessage = nil
        } catch NearifyContactsError.permissionDenied {
            contacts = []
            if permissionStatus == .notDetermined {
                errorMessage = "Enable Contacts access in Settings to view contacts saved or enhanced through Nearify."
            } else {
                errorMessage = "Contacts access is off. Enable access in Settings to view Nearify-enhanced contacts."
            }
        } catch {
            contacts = []
            errorMessage = "Unable to load local contacts right now."
        }
    }

    private func refreshPermissionAndReload() async {
        permissionStatus = CNContactStore.authorizationStatus(for: .contacts)
        await reload()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func search() async {
        do {
            contacts = try await NearifyContactsIndexService.shared.searchNearifyContacts(query: query)
        } catch {
            contacts = []
        }
    }
}
