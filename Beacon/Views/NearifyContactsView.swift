import SwiftUI
import Contacts
import UIKit

struct NearifyContactsView: View {
    @State private var contacts: [NearifyContactSearchResult] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var permissionStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var isRequestingPermission = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Nearify Contacts…")
                    .tint(.white)
                    .foregroundColor(.white)
            } else if shouldShowAllowAccess {
                VStack(spacing: 10) {
                    Text("Allow Contact Access")
                        .font(.headline)
                    Text("Nearify can search contacts that were saved or enhanced through Nearify.\n\nOn iOS, you may be asked whether to share selected contacts or all contacts.\n\nChoose “Share All Contacts” to let Nearify search all Nearify-enhanced contacts.\nChoose “Select Contacts” if you only want Nearify to search specific contacts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(isRequestingPermission ? "Requesting…" : "Allow Contact Access") {
                        Task { await requestContactsAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequestingPermission)
                }
                .padding()
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
            } else {
                VStack(spacing: 0) {
                    if shouldShowLimitedBanner {
                        limitedAccessBanner
                    }

                    if contacts.isEmpty {
                        ContentUnavailableView("No Nearify Contacts Yet", systemImage: "person.crop.circle.badge.questionmark", description: Text("Contacts saved through Nearify will appear here once they include Nearify profile links."))
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
        .onDisappear {
            #if DEBUG
            print("[PeopleNav] NearifyContactsView unmounted")
            #endif
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
            if shouldShowOpenSettings {
                errorMessage = "Contacts access is off. Enable access in Settings to view contacts saved or enhanced through Nearify."
            } else {
                errorMessage = nil
            }
        } catch NearifyContactsError.loadFailed {
            contacts = []
            errorMessage = "Unable to load contacts right now."
        } catch {
            contacts = []
            errorMessage = "Unable to load contacts right now."
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


extension NearifyContactsView {
    private var shouldShowAllowAccess: Bool {
        permissionStatus == .notDetermined
    }

    private var shouldShowOpenSettings: Bool {
        permissionStatus == .denied || permissionStatus == .restricted
    }

    private var shouldShowLimitedBanner: Bool {
        if #available(iOS 18.0, *) {
            return permissionStatus == .limited
        }
        return false
    }

    private var limitedAccessBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Limited Contacts Access")
                .font(.subheadline.weight(.semibold))
            Text("Nearify can only search the contacts you selected. To search all Nearify-enhanced contacts, allow full Contacts access in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Open Settings") {
                openAppSettings()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func requestContactsAccess() async {
        isRequestingPermission = true
        defer { isRequestingPermission = false }

        let store = CNContactStore()
        _ = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        await refreshPermissionAndReload()
    }
}
