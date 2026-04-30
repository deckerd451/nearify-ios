import Foundation
import Combine
import Supabase
import UIKit

@MainActor
final class ContactShareService: ObservableObject {
    static let shared = ContactShareService()

    @Published var incomingPendingRequest: ContactShareRequest?
    @Published var outgoingPendingRequests: [UUID: ContactShareRequest] = [:]

    private let supabase = AppEnvironment.shared.supabaseClient
    private var pollTask: Task<Void, Never>?
    private var currentProfileId: UUID?
    private var lastPresentedIncomingRequestId: UUID?
    private var appStateObservers: [NSObjectProtocol] = []
    private var isAppActive = true

    private init() {
        isAppActive = UIApplication.shared.applicationState == .active
        installAppStateObservers()
    }

    func start(for profileId: UUID) {
        if currentProfileId == profileId, pollTask != nil {
            return
        }

        stop()

        currentProfileId = profileId
        if appStateObservers.isEmpty {
            installAppStateObservers()
        }
        isAppActive = UIApplication.shared.applicationState == .active
        pollTask = Task { [weak self] in
            guard let self else { return }
            print("[ContactShare] polling started profile=\(profileId.uuidString)")
            while !Task.isCancelled {
                if self.isAppActive {
                    await self.pollIncomingRequests(for: profileId)
                    await self.pollOutgoingRequests(for: profileId)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        removeAppStateObservers()
        currentProfileId = nil
        incomingPendingRequest = nil
        outgoingPendingRequests = [:]
        print("[ContactShare] polling stopped")
    }

    func pollIncomingRequests(for profileId: UUID) async {
        let rows: [ContactShareRequest]
        do {
            rows = try await supabase
                .from("connections")
                .select("id,requester_profile_id,addressee_profile_id,event_id,status,created_at,updated_at")
                .eq("addressee_profile_id", value: profileId.uuidString)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
        } catch {
            return
        }

        guard let request = rows.first else {
            incomingPendingRequest = nil
            return
        }

        if lastPresentedIncomingRequestId == request.id {
            return
        }

        if incomingPendingRequest?.id != request.id {
            print("[ContactShare] incoming request detected requester=\(request.requesterProfileId.uuidString) request=\(request.id.uuidString)")
            incomingPendingRequest = request
        }
    }

    func approve(_ request: ContactShareRequest) async {
        do {
            try await supabase
                .from("connections")
                .update(["status": "accepted"])
                .eq("id", value: request.id.uuidString)
                .eq("status", value: "pending")
                .execute()

            print("[ContactShare] approved request=\(request.id.uuidString)")
            lastPresentedIncomingRequestId = request.id
            incomingPendingRequest = nil
        } catch {
            return
        }
    }

    func ignore(_ request: ContactShareRequest) async {
        do {
            try await supabase
                .from("connections")
                .update(["status": "ignored"])
                .eq("id", value: request.id.uuidString)
                .eq("status", value: "pending")
                .execute()

            print("[ContactShare] ignored request=\(request.id.uuidString)")
            lastPresentedIncomingRequestId = request.id
            incomingPendingRequest = nil
        } catch {
            return
        }
    }

    func requestContact(
        requesterProfileId: UUID,
        addresseeProfileId: UUID,
        eventId: UUID?
    ) async throws {
        let existingRows: [ContactShareRequest] = try await supabase
            .from("connections")
            .select("id,requester_profile_id,addressee_profile_id,event_id,status,created_at,updated_at")
            .or("and(requester_profile_id.eq.\(requesterProfileId.uuidString),addressee_profile_id.eq.\(addresseeProfileId.uuidString)),and(requester_profile_id.eq.\(addresseeProfileId.uuidString),addressee_profile_id.eq.\(requesterProfileId.uuidString))")
            .order("created_at", ascending: false)
            .execute()
            .value

        if existingRows.contains(where: { $0.status.lowercased() == "accepted" }) {
            return
        }

        if let existingOutgoingPending = existingRows.first(where: {
            $0.requesterProfileId == requesterProfileId &&
            $0.addresseeProfileId == addresseeProfileId &&
            $0.status.lowercased() == "pending"
        }) {
            outgoingPendingRequests[addresseeProfileId] = existingOutgoingPending
            return
        }

        struct RequestPayload: Encodable {
            let requesterProfileId: UUID
            let addresseeProfileId: UUID
            let eventId: UUID?
            let status: String

            enum CodingKeys: String, CodingKey {
                case requesterProfileId = "requester_profile_id"
                case addresseeProfileId = "addressee_profile_id"
                case eventId = "event_id"
                case status
            }
        }

        let payload = RequestPayload(
            requesterProfileId: requesterProfileId,
            addresseeProfileId: addresseeProfileId,
            eventId: eventId,
            status: "pending"
        )

        if let reusable = existingRows.first(where: {
            $0.requesterProfileId == requesterProfileId &&
            $0.addresseeProfileId == addresseeProfileId &&
            $0.status.lowercased() != "accepted"
        }) {
            try await supabase
                .from("connections")
                .update(payload)
                .eq("id", value: reusable.id.uuidString)
                .execute()
        } else {
            try await supabase
                .from("connections")
                .insert(payload)
                .execute()
        }

        print("[ContactShare] request sent requester=\(requesterProfileId.uuidString) receiver=\(addresseeProfileId.uuidString)")
    }

    func statusBetween(_ a: UUID, _ b: UUID) async -> String? {
        let rows: [ContactShareRequest]
        do {
            rows = try await supabase
                .from("connections")
                .select("id,requester_profile_id,addressee_profile_id,event_id,status,created_at,updated_at")
                .or("and(requester_profile_id.eq.\(a.uuidString),addressee_profile_id.eq.\(b.uuidString)),and(requester_profile_id.eq.\(b.uuidString),addressee_profile_id.eq.\(a.uuidString))")
                .order("updated_at", ascending: false)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
        } catch {
            return nil
        }

        let rawStatus = rows.first?.status.lowercased()
        let normalizedStatus: String
        switch rawStatus {
        case "accepted":
            normalizedStatus = "accepted"
        case "pending":
            normalizedStatus = "pending"
        default:
            normalizedStatus = "none"
        }

        print("[ContactShare] using connection status=\(normalizedStatus)")
        return normalizedStatus
    }

    private func pollOutgoingRequests(for profileId: UUID) async {
        let rows: [ContactShareRequest]
        do {
            rows = try await supabase
                .from("connections")
                .select("id,requester_profile_id,addressee_profile_id,event_id,status,created_at,updated_at")
                .eq("requester_profile_id", value: profileId.uuidString)
                .eq("status", value: "pending")
                .execute()
                .value
        } catch {
            return
        }

        outgoingPendingRequests = Dictionary(uniqueKeysWithValues: rows.map { ($0.addresseeProfileId, $0) })
    }

    private func installAppStateObservers() {
        let center = NotificationCenter.default

        appStateObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isAppActive = true
                }
            }
        )

        appStateObservers.append(
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isAppActive = false
                }
            }
        )
    }

    private func removeAppStateObservers() {
        let center = NotificationCenter.default
        for observer in appStateObservers {
            center.removeObserver(observer)
        }
        appStateObservers.removeAll()
    }
}
