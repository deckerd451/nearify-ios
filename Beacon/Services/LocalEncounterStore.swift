import Foundation
import Combine
import Supabase

/// Passive local-first encounter capture layer.
///
/// Records BLE-based encounter fragments independently of the existing
/// EncounterService (which writes to Supabase) and NearbyModeTracker
/// (which drives the Nearby Mode UI).
///
/// This store:
/// - Captures raw BLE proximity fragments from BCN- devices
/// - Persists to a local JSON file (survives backgrounding, sleep, offline)
/// - Does NOT create interaction_events or modify event_attendees
/// - Does NOT alter feed ranking or People/Home logic
/// - Does NOT upload to Supabase (future work)
/// - Does NOT change any visible app behavior
///
/// Data is isolated for future use by goodbye flows and release features.
@MainActor
final class LocalEncounterStore {

    static let shared = LocalEncounterStore()

    // MARK: - Model

    /// A captured encounter fragment from BLE proximity detection.
    struct CapturedEncounter: Codable, Identifiable {
        let encounterId: UUID
        var eventId: UUID?
        let peerEphemeralId: String     // BLE prefix (8-char hex from BCN-<prefix>)
        var resolvedProfileId: UUID?    // Resolved from ProfileCache if available
        var firstSeenAt: Date
        var lastSeenAt: Date
        var duration: Int               // Accumulated seconds of proximity
        var signalStrengthSummary: SignalSummary
        var confidenceScore: Double     // 0.0–1.0 based on duration + signal quality
        var uploadStatus: UploadStatus

        var id: UUID { encounterId }

        struct SignalSummary: Codable {
            var sampleCount: Int
            var strongestRSSI: Int
            var weakestRSSI: Int
            var latestRSSI: Int
            var averageRSSI: Double

            mutating func addSample(_ rssi: Int) {
                sampleCount += 1
                latestRSSI = rssi
                if rssi > strongestRSSI { strongestRSSI = rssi }
                if rssi < weakestRSSI { weakestRSSI = rssi }
                // Running average
                averageRSSI = averageRSSI + (Double(rssi) - averageRSSI) / Double(sampleCount)
            }
        }

        enum UploadStatus: String, Codable {
            case local      // Not yet uploaded
            case pending    // Queued for upload
            case uploaded   // Successfully synced
            case failed     // Upload attempted but failed
        }
    }

    // MARK: - State

    private var encounters: [String: CapturedEncounter] = [:]  // keyed by peerEphemeralId
    private var cancellable: AnyCancellable?
    private var saveTask: Task<Void, Never>?
    private var isCapturing = false

    private let fileName = "local_encounters.json"
    private let maxEncounters = 200
    private let pruneAge: TimeInterval = 7 * 24 * 3600  // 7 days

    private init() {
        loadFromDisk()
    }

    // MARK: - Start / Stop

    /// Begin passively capturing BLE encounter fragments.
    /// Safe to call multiple times — idempotent.
    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        cancellable = BLEScannerService.shared.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.processDevices(devices)
            }

        #if DEBUG
        print("[LocalEncounter] capture started (\(encounters.count) existing fragments)")
        #endif
    }

    /// Stop capturing. Persists current state to disk.
    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        cancellable?.cancel()
        cancellable = nil

        // Finalize all active encounters
        let keys = Array(encounters.keys)
        for key in keys {
            if var enc = encounters[key] {
                enc.confidenceScore = computeConfidence(enc)
                encounters[key] = enc
            }
        }

        persistToDisk()

        #if DEBUG
        let active = encounters.values.filter { $0.duration > 0 }.count
        print("[LocalEncounter] capture stopped — \(active) fragments finalized")
        #endif
    }

    // MARK: - Processing

    private func processDevices(_ devices: [UUID: DiscoveredBLEDevice]) {
        let now = Date()
        let eventId = EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) }
        let bcnDevices = devices.values.filter { $0.name.hasPrefix("BCN-") }

        var didUpdate = false

        for device in bcnDevices {
            guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { continue }

            // Skip self
            if let myId = AuthService.shared.currentUser?.id {
                let myPrefix = String(myId.uuidString.prefix(8)).lowercased()
                if prefix == myPrefix { continue }
            }

            let rssi = BLEScannerService.shared.smoothedRSSI(for: device.id) ?? device.rssi

            if var existing = encounters[prefix] {
                // Update existing fragment
                let elapsed = Int(now.timeIntervalSince(existing.lastSeenAt))
                // Only accumulate if the gap is reasonable (< 30s means continuous proximity)
                if elapsed <= 30 {
                    existing.duration += elapsed
                }
                existing.lastSeenAt = now
                existing.signalStrengthSummary.addSample(rssi)
                existing.confidenceScore = computeConfidence(existing)

                // Update event ID if we now have one and didn't before
                if existing.eventId == nil, let eventId {
                    existing.eventId = eventId
                }

                // Try to resolve profile ID if not yet resolved
                if existing.resolvedProfileId == nil {
                    existing.resolvedProfileId = ProfileCache.shared.profile(forPrefix: prefix)?.id
                }

                encounters[prefix] = existing
                didUpdate = true
            } else {
                // New encounter fragment
                let resolvedId = ProfileCache.shared.profile(forPrefix: prefix)?.id

                let fragment = CapturedEncounter(
                    encounterId: UUID(),
                    eventId: eventId,
                    peerEphemeralId: prefix,
                    resolvedProfileId: resolvedId,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    duration: 0,
                    signalStrengthSummary: CapturedEncounter.SignalSummary(
                        sampleCount: 1,
                        strongestRSSI: rssi,
                        weakestRSSI: rssi,
                        latestRSSI: rssi,
                        averageRSSI: Double(rssi)
                    ),
                    confidenceScore: 0.0,
                    uploadStatus: .local
                )

                encounters[prefix] = fragment
                didUpdate = true

                #if DEBUG
                let resolved = resolvedId != nil ? "resolved" : "unresolved"
                print("[LocalEncounter] created: prefix=\(prefix) (\(resolved))")
                #endif
            }
        }

        // Throttled persistence — save at most every 30 seconds
        if didUpdate {
            scheduleSave()
        }
    }

    // MARK: - Confidence

    private func computeConfidence(_ encounter: CapturedEncounter) -> Double {
        // Confidence based on duration and signal quality
        let durationScore = min(Double(encounter.duration) / 300.0, 1.0)  // caps at 5 min
        let signalScore: Double = {
            let avg = encounter.signalStrengthSummary.averageRSSI
            if avg >= -50 { return 1.0 }
            if avg >= -65 { return 0.8 }
            if avg >= -80 { return 0.5 }
            return 0.2
        }()
        let sampleScore = min(Double(encounter.signalStrengthSummary.sampleCount) / 20.0, 1.0)

        return min((durationScore * 0.5 + signalScore * 0.3 + sampleScore * 0.2), 1.0)
    }

    // MARK: - Persistence

    private var lastSaveTime: Date = .distantPast
    private let saveInterval: TimeInterval = 30.0

    private func scheduleSave() {
        let elapsed = Date().timeIntervalSince(lastSaveTime)
        guard elapsed >= saveInterval else { return }

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Small delay to batch rapid updates
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.persistToDisk()
        }
    }

    private func persistToDisk() {
        lastSaveTime = Date()

        let values = Array(encounters.values)
        guard let data = try? JSONEncoder().encode(values) else {
            #if DEBUG
            print("[LocalEncounter] ❌ encode failed")
            #endif
            return
        }

        do {
            let url = fileURL()
            try data.write(to: url, options: .atomic)
            #if DEBUG
            let kb = data.count / 1024
            print("[LocalEncounter] 💾 saved \(values.count) fragments (\(kb)KB)")
            #endif
        } catch {
            #if DEBUG
            print("[LocalEncounter] ❌ write failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func loadFromDisk() {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode([CapturedEncounter].self, from: data)

            // Prune old encounters and cap total count
            let cutoff = Date().addingTimeInterval(-pruneAge)
            let pruned = saved
                .filter { $0.lastSeenAt > cutoff }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(maxEncounters)

            encounters = Dictionary(uniqueKeysWithValues: pruned.map { ($0.peerEphemeralId, $0) })

            #if DEBUG
            print("[LocalEncounter] loaded \(encounters.count) fragments from disk (pruned \(saved.count - encounters.count))")
            #endif
        } catch {
            #if DEBUG
            print("[LocalEncounter] ❌ load failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func fileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(fileName)
    }

    // MARK: - Queries (for future use by goodbye/release flows)

    /// All captured encounters, sorted by most recent.
    var allEncounters: [CapturedEncounter] {
        encounters.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Encounters with meaningful duration (>= 30 seconds).
    var significantEncounters: [CapturedEncounter] {
        allEncounters.filter { $0.duration >= 30 }
    }

    /// Encounters for a specific event.
    func encounters(forEvent eventId: UUID) -> [CapturedEncounter] {
        allEncounters.filter { $0.eventId == eventId }
    }

    /// Encounters that haven't been uploaded yet.
    var pendingUpload: [CapturedEncounter] {
        allEncounters.filter { $0.uploadStatus == .local || $0.uploadStatus == .failed }
    }

    /// Total count of captured fragments.
    var count: Int { encounters.count }

    // MARK: - Fragment Upload (Step 2 of Release System)

    private var isUploading = false

    /// Uploads all pending local encounter fragments to Supabase.
    /// Fire-and-forget — does not block UI. Safe to call multiple times.
    func uploadPendingFragments() {
        guard !isUploading else { return }
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("[Release] upload skipped — offline")
            #endif
            return
        }
        guard let myProfileId = AuthService.shared.currentUser?.id else {
            #if DEBUG
            print("[Release] upload skipped — no current user")
            #endif
            return
        }

        let pending = encounters.values.filter {
            $0.uploadStatus == .local || $0.uploadStatus == .failed
        }
        guard !pending.isEmpty else {
            #if DEBUG
            print("[Release] upload skipped — no pending fragments")
            #endif
            return
        }

        isUploading = true

        #if DEBUG
        print("[Release] uploading \(pending.count) encounter fragments")
        #endif

        Task {
            let supabase = AppEnvironment.shared.supabaseClient
            var successCount = 0
            var failCount = 0

            for fragment in pending {
                let payload = FragmentUploadPayload(
                    uploader_profile_id: myProfileId.uuidString,
                    event_id: fragment.eventId?.uuidString,
                    peer_ephemeral_id: fragment.peerEphemeralId,
                    peer_resolved_profile_id: fragment.resolvedProfileId?.uuidString,
                    device_encounter_id: fragment.encounterId.uuidString,
                    first_seen_at: ISO8601DateFormatter().string(from: fragment.firstSeenAt),
                    last_seen_at: ISO8601DateFormatter().string(from: fragment.lastSeenAt),
                    duration_seconds: fragment.duration,
                    avg_rssi: fragment.signalStrengthSummary.averageRSSI,
                    confidence_score: fragment.confidenceScore
                )

                do {
                    try await supabase
                        .from("encounter_fragments")
                        .upsert(payload, onConflict: "uploader_profile_id,device_encounter_id")
                        .execute()

                    // Mark as uploaded
                    if var enc = self.encounters[fragment.peerEphemeralId],
                       enc.encounterId == fragment.encounterId {
                        enc.uploadStatus = .uploaded
                        self.encounters[fragment.peerEphemeralId] = enc
                    }
                    successCount += 1
                } catch {
                    // Mark as failed — will retry next cycle
                    if var enc = self.encounters[fragment.peerEphemeralId],
                       enc.encounterId == fragment.encounterId {
                        enc.uploadStatus = .failed
                        self.encounters[fragment.peerEphemeralId] = enc
                    }
                    failCount += 1
                    #if DEBUG
                    print("[Release] fragment upload failed: \(fragment.peerEphemeralId) — \(error.localizedDescription)")
                    #endif
                }
            }

            self.persistToDisk()
            self.isUploading = false

            #if DEBUG
            print("[Release] fragment upload complete: \(successCount) success, \(failCount) failed")
            #endif

            // After upload, trigger matching
            if successCount > 0 {
                await ReleaseService.shared.matchFragments()
            }
        }
    }
}

// MARK: - Upload Payload

private struct FragmentUploadPayload: Encodable {
    let uploader_profile_id: String
    let event_id: String?
    let peer_ephemeral_id: String
    let peer_resolved_profile_id: String?
    let device_encounter_id: String
    let first_seen_at: String
    let last_seen_at: String
    let duration_seconds: Int
    let avg_rssi: Double
    let confidence_score: Double
}
