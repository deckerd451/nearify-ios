import Foundation
import Combine

/// Lightweight local encounter tracker for Nearby Mode.
/// Tracks BLE-detected peers with dwell time, first/last seen, and strongest RSSI.
/// Works entirely offline — no backend dependency.
/// Persists briefly to UserDefaults so encounters survive backgrounding.
@MainActor
final class NearbyModeTracker: ObservableObject {

    static let shared = NearbyModeTracker()

    /// A single local encounter record.
    struct LocalEncounter: Identifiable, Codable {
        let id: String              // BLE prefix (8-char hex) or profileId string
        var profileId: UUID?        // Resolved profile ID (if cached)
        var name: String            // Resolved name or "Nearby attendee"
        var avatarUrl: String?      // Resolved avatar (if cached)
        var firstSeen: Date
        var lastSeen: Date
        var strongestRSSI: Int      // Best signal observed
        var latestRSSI: Int         // Most recent signal

        var dwellSeconds: Int {
            Int(lastSeen.timeIntervalSince(firstSeen))
        }

        var dwellText: String {
            let s = dwellSeconds
            if s < 60 { return "Just now" }
            let m = s / 60
            if m == 1 { return "About a minute" }
            return "About \(m) minutes"
        }

        var lastSeenText: String {
            let age = Int(Date().timeIntervalSince(lastSeen))
            if age < 30 { return "Seen just now" }
            if age < 60 { return "Seen \(age)s ago" }
            let m = age / 60
            if m == 1 { return "Seen 1 min ago" }
            return "Seen \(m) min ago"
        }

        var signalLabel: String {
            switch latestRSSI {
            case -40...0:    return "Very close"
            case -60..<(-40): return "Nearby"
            case -80..<(-60): return "Farther away"
            default:          return "At the edge"
            }
        }
    }

    @Published private(set) var encounters: [LocalEncounter] = []

    private var cancellable: AnyCancellable?
    private let persistKey = "nearbyMode.encounters"

    private init() {
        loadFromDisk()
        loadPendingFromDisk()
    }

    // MARK: - Observation

    /// Start tracking BLE peers. Call when entering Nearby Mode.
    /// Also ensures BLE scanning is active — in Nearby Mode, scanning runs
    /// independently of event join state.
    func startTracking() {
        guard cancellable == nil else { return }

        // Ensure BLE scanner is running — in Nearby Mode we scan without an event join
        if !BLEScannerService.shared.isScanning {
            BLEScannerService.shared.startScanning()
            #if DEBUG
            print("[NearbyMode] started BLE scanning for Nearby Mode")
            #endif
        }

        // Start BLE advertising with cached identity if available.
        // This allows other nearby devices to detect this user even without
        // an active event join. Uses the cached profile ID as the community identity.
        if !BLEAdvertiserService.shared.isAdvertising,
           let profileId = AuthService.shared.currentUser?.id {
            BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
            #if DEBUG
            print("[NearbyMode] started BLE advertising with cached identity: \(profileId.uuidString.prefix(8))")
            #endif
        }

        #if DEBUG
        print("[NearbyMode] BLE active — starting local encounter tracking")
        #endif

        // Also start the passive local encounter capture layer
        LocalEncounterStore.shared.startCapture()

        cancellable = BLEScannerService.shared.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.processDevices(devices)
            }
    }

    /// Stop tracking. Call when leaving Nearby Mode.
    func stopTracking() {
        cancellable?.cancel()
        cancellable = nil
        saveToDisk()

        // Also stop the passive local encounter capture layer
        LocalEncounterStore.shared.stopCapture()
    }

    // MARK: - Processing

    private func processDevices(_ devices: [UUID: DiscoveredBLEDevice]) {
        let now = Date()
        let bcnDevices = devices.values.filter { $0.name.hasPrefix("BCN-") }

        var updated = false

        for device in bcnDevices {
            guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { continue }

            let smoothedRSSI = BLEScannerService.shared.smoothedRSSI(for: device.id) ?? device.rssi

            if let idx = encounters.firstIndex(where: { $0.id == prefix }) {
                // Update existing encounter
                encounters[idx].lastSeen = now
                encounters[idx].latestRSSI = smoothedRSSI
                if smoothedRSSI > encounters[idx].strongestRSSI {
                    encounters[idx].strongestRSSI = smoothedRSSI
                }
                // Re-resolve name if it was anonymous and cache now has data
                if encounters[idx].name == "Nearby attendee" {
                    let resolved = resolveIdentity(prefix: prefix)
                    encounters[idx].name = resolved.name
                    encounters[idx].avatarUrl = resolved.avatarUrl
                    encounters[idx].profileId = resolved.profileId
                }
                updated = true
            } else {
                // New encounter
                let identity = resolveIdentity(prefix: prefix)
                let encounter = LocalEncounter(
                    id: prefix,
                    profileId: identity.profileId,
                    name: identity.name,
                    avatarUrl: identity.avatarUrl,
                    firstSeen: now,
                    lastSeen: now,
                    strongestRSSI: smoothedRSSI,
                    latestRSSI: smoothedRSSI
                )
                encounters.append(encounter)
                updated = true

                #if DEBUG
                print("[NearbyMode] local encounter tracked: \(identity.name) (prefix: \(prefix))")
                #endif
            }
        }

        if updated {
            // Sort: most recently seen first, then by signal strength
            encounters.sort { a, b in
                if abs(a.lastSeen.timeIntervalSince(b.lastSeen)) < 5 {
                    return a.latestRSSI > b.latestRSSI
                }
                return a.lastSeen > b.lastSeen
            }
        }
    }

    // MARK: - Identity Resolution

    private struct ResolvedIdentity {
        let profileId: UUID?
        let name: String
        let avatarUrl: String?
    }

    private func resolveIdentity(prefix: String) -> ResolvedIdentity {
        let cache = ProfileCache.shared
        if let cached = cache.profile(forPrefix: prefix) {
            return ResolvedIdentity(
                profileId: cached.id,
                name: cached.name,
                avatarUrl: cached.avatarUrl
            )
        }
        return ResolvedIdentity(
            profileId: nil,
            name: "Nearby attendee",
            avatarUrl: nil
        )
    }

    // MARK: - Persistence (lightweight, survives backgrounding)

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(encounters) else { return }
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let saved = try? JSONDecoder().decode([LocalEncounter].self, from: data) else { return }

        // Only restore encounters from the last 24 hours
        let cutoff = Date().addingTimeInterval(-86400)
        encounters = saved.filter { $0.lastSeen > cutoff }
    }

    /// Clear all tracked encounters.
    func clear() {
        encounters = []
        UserDefaults.standard.removeObject(forKey: persistKey)
    }

    // MARK: - Queries

    /// Encounters currently visible via BLE (seen in last 15 seconds).
    var activeEncounters: [LocalEncounter] {
        let cutoff = Date().addingTimeInterval(-15)
        return encounters.filter { $0.lastSeen > cutoff }
    }

    /// Encounters no longer visible but seen recently (last 24 hours).
    var recentEncounters: [LocalEncounter] {
        let activeCutoff = Date().addingTimeInterval(-15)
        let recentCutoff = Date().addingTimeInterval(-86400)
        return encounters.filter { $0.lastSeen <= activeCutoff && $0.lastSeen > recentCutoff }
    }

    /// All confirmed encounters (pending or synced), most recent first.
    var confirmedEncounters: [PendingConfirmation] {
        pendingConfirmations.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Confirmed Encounters (deferred sync)

    /// A confirmed nearby encounter — user tapped "Save encounter" in Nearby Mode.
    /// Queued for sync when connectivity returns.
    struct PendingConfirmation: Codable, Identifiable {
        let id: UUID
        let localProfileId: UUID
        let remoteProfileId: UUID?
        let blePrefix: String
        let remoteName: String
        let timestamp: Date
        let dwellSeconds: Int
        let strongestRSSI: Int
        var syncStatus: SyncStatus

        enum SyncStatus: String, Codable {
            case pending
            case synced
            case failed
        }
    }

    @Published private(set) var pendingConfirmations: [PendingConfirmation] = []
    @Published private(set) var lastSyncedCount: Int = 0
    private let pendingKey = "nearbyMode.pendingConfirmations"

    /// Confirm a nearby encounter locally. Stores it for deferred sync.
    func confirmEncounter(_ encounter: LocalEncounter) {
        let localId = AuthService.shared.currentUser?.id ?? UUID()

        let confirmation = PendingConfirmation(
            id: UUID(),
            localProfileId: localId,
            remoteProfileId: encounter.profileId,
            blePrefix: encounter.id,
            remoteName: encounter.name,
            timestamp: Date(),
            dwellSeconds: encounter.dwellSeconds,
            strongestRSSI: encounter.strongestRSSI,
            syncStatus: .pending
        )

        pendingConfirmations.append(confirmation)
        savePendingToDisk()

        #if DEBUG
        print("[NearbyMode] local encounter confirmed: \(encounter.name) (prefix: \(encounter.id))")
        print("[NearbyMode] queued for sync")
        #endif
    }

    /// Check if an encounter (by BLE prefix) has already been confirmed.
    func isConfirmed(prefix: String) -> Bool {
        pendingConfirmations.contains { $0.blePrefix == prefix }
    }

    /// Check if an encounter (by profile ID) has already been confirmed.
    func isConfirmed(profileId: UUID) -> Bool {
        pendingConfirmations.contains { $0.remoteProfileId == profileId }
    }

    /// Attempt to sync all pending confirmations to the backend.
    /// Called when connectivity returns. Updates `lastSyncedCount` on completion.
    func syncPendingConfirmations() {
        let pending = pendingConfirmations.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else {
            lastSyncedCount = 0
            return
        }

        var syncedCount = 0
        

        for confirmation in pending {
            guard let remoteId = confirmation.remoteProfileId else { continue }

            Task {
                do {
                    let result = try await ConnectionService.shared.createConnectionIfNeeded(
                        to: remoteId.uuidString
                    )
                    if let idx = self.pendingConfirmations.firstIndex(where: { $0.id == confirmation.id }) {
                        self.pendingConfirmations[idx].syncStatus = .synced
                        syncedCount += 1
                        #if DEBUG
                        print("[NearbyMode] synced: \(confirmation.remoteName) (prefix: \(confirmation.blePrefix))")
                        #endif
                    }
                    self.savePendingToDisk()
                    self.lastSyncedCount = syncedCount
                    _ = result
                } catch {
                    if let idx = self.pendingConfirmations.firstIndex(where: { $0.id == confirmation.id }) {
                        self.pendingConfirmations[idx].syncStatus = .failed
                    }
                    self.savePendingToDisk()
                    #if DEBUG
                    print("[NearbyMode] sync failed for \(confirmation.remoteName): \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    private func savePendingToDisk() {
        guard let data = try? JSONEncoder().encode(pendingConfirmations) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    func loadPendingFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let saved = try? JSONDecoder().decode([PendingConfirmation].self, from: data) else { return }
        pendingConfirmations = saved.filter { $0.syncStatus == .pending }
    }
}
