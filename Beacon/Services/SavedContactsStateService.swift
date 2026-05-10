import Foundation

@MainActor
final class SavedContactsStateService: ObservableObject {
    static let shared = SavedContactsStateService()

    @Published private(set) var savedProfileIds: Set<UUID> = []
    private var loading = false

    private init() {}

    func requestRefresh() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let contacts = try await NearifyContactsIndexService.shared.loadNearifyContacts()
                savedProfileIds = Set(contacts.compactMap(\.profileID))
            } catch {
                // Preserve existing set on permission/network failures.
            }
        }
    }
}
