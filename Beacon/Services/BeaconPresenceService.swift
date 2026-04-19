import Foundation
import Combine

// MARK: - Event Zone State

/// Environmental confidence derived from beacon detection.
/// This is a passive signal — it does NOT control event participation.
/// Event participation is always driven by QR join + event_attendees.
enum EventZoneState: String {
    /// No beacon signal detected.
    case outside
    /// Beacon was recently seen but signal is not current.
    case unknown
    /// Beacon is actively visible right now.
    case inside
}

// MARK: - Beacon Presence Service
//
// Clean, reusable environmental signal layer.
//
// PURPOSE:
//   Beacon detection is an ENHANCEMENT, not a requirement.
//   The app works fully without any physical beacon present.
//   When a beacon IS visible, this service strengthens event presence
//   confidence and supports soft recovery after interruptions.
//
// DETECTION PIPELINE (unified):
//   Three independent detection paths feed into this service:
//
//   1. CBCentralManager path (BLEScannerService)
//      - Sees BLE GATT advertisements (BCN-, ANCHOR-, BEACON-, MOONSIDE devices)
//      - Cannot see iBeacon advertisements (Apple restriction)
//      - Used for: peer BLE detection, MOONSIDE-branded anchors, organizer anchors
//
//   2. CLLocationManager path (BLEService)
//      - Sees iBeacon advertisements via ranging
//      - Matched against BeaconRegistryService (public.beacons table)
//      - Published as BLEService.latestRangedAnchor
//      - Used for: physical event anchor beacons (iBeacon hardware)
//
//   3. Organizer anchor phone (ANCHOR-<prefix> via CBCentralManager)
//      - An organizer in host anchor mode broadcasts ANCHOR-<prefix>
//      - Distinct from normal peer BLE (BCN-<prefix>)
//      - Recognized as event zone signal on attendee devices
//
//   An anchor is detected if ANY path reports a qualifying signal.
//   The strongest signal across all paths wins.
//
// DESIGN RULES:
//   - No direct UI navigation or screen updates.
//   - No event joins or leaves — that's EventJoinService's job.
//   - No competing heartbeat — EventPresenceService owns the heartbeat.
//   - Beacon state is advisory: downstream consumers decide what to do with it.
//
// INTEGRATION POINTS:
//   - EventPresenceService reads zone state to boost confidence on heartbeat ticks.
//   - EventJoinService reads zone state to support soft recovery after background.
//   - Future: FindAttendeeView can check isInBeaconZone for eligibility.

@MainActor
final class BeaconPresenceService: ObservableObject {

    static let shared = BeaconPresenceService()

    // MARK: - Published State (read-only for consumers)

    /// Whether a known event beacon is currently visible.
    @Published private(set) var isBeaconVisible: Bool = false

    /// When the beacon was last detected. Nil if never seen.
    @Published private(set) var lastBeaconSeenAt: Date?

    /// Normalized confidence value (0.0–1.0) based on RSSI and signal stability.
    @Published private(set) var beaconConfidence: Double = 0.0

    /// High-level zone classification for downstream consumers.
    @Published private(set) var currentZoneState: EventZoneState = .outside

    /// Which detection path produced the current anchor signal.
    /// Exposed for diagnostics only.
    @Published private(set) var anchorSource: String = "none"

    // MARK: - Private State

    private let scanner = BLEScannerService.shared
    private let bleService = BLEService.shared
    private var cancellables = Set<AnyCancellable>()
    private var evaluationTimer: Timer?

    /// How long after last beacon sighting before we consider the user "outside".
    /// Conservative: BLE can drop briefly due to body shielding, interference, etc.
    private let signalLossGracePeriod: TimeInterval = 30.0

    /// Beacons must meet this RSSI threshold to count as "visible" (CBCentralManager path).
    private let rssiThreshold: Int = -80

    /// Beacons older than this are stale and ignored (CBCentralManager path).
    private let freshnessWindow: TimeInterval = 12.0

    /// iBeacon ranging results older than this are stale (CLLocationManager path).
    /// CLLocationManager ranges at ~1Hz; BLEService processes at 1.5s intervals.
    /// 5s is generous enough to survive a missed cycle.
    private let iBeaconFreshnessWindow: TimeInterval = 5.0

    // Log dedup: avoid spamming identical state every tick.
    private var lastLogSignature: String = ""

    private init() {
        startMonitoring()
    }

    deinit {
        evaluationTimer?.invalidate()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Path 1: React to CBCentralManager scanner updates (batched at 2x/sec).
        scanner.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        // Path 2: React to CLLocationManager iBeacon ranging results.
        // BLEService publishes latestRangedAnchor when processBeacons() runs (~1.5s).
        bleService.$latestRangedAnchor
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        // Periodic fallback evaluation for signal loss detection.
        // 5s is sufficient — we're not driving UI, just updating advisory state.
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluate() }
        }
    }

    // MARK: - Evaluation (unified: CBCentralManager + CLLocationManager + organizer anchor)

    private func evaluate() {
        let now = Date()

        // --- Path 1: CBCentralManager hardware anchors (MOONSIDE-branded BLE GATT devices) ---
        let cbAnchors = scanner.getKnownBeacons()
            .filter { device in
                isCBHardwareAnchor(device.name)
                && device.rssi >= rssiThreshold
                && now.timeIntervalSince(device.lastSeen) < freshnessWindow
            }
            .sorted { $0.rssi > $1.rssi }

        let cbBest: (rssi: Int, source: String)? = cbAnchors.first.map {
            (rssi: $0.rssi, source: "hardware:\($0.name)")
        }

        // --- Path 2: CLLocationManager iBeacon anchors (registered hardware beacons) ---
        let clBest: (rssi: Int, source: String)?
        if let ranged = bleService.latestRangedAnchor,
           now.timeIntervalSince(ranged.lastSeen) < iBeaconFreshnessWindow,
           ranged.rssi >= rssiThreshold {
            clBest = (rssi: ranged.rssi, source: "ibeacon:\(ranged.label)")
        } else {
            clBest = nil
        }

        // --- Path 3: Organizer anchor phone (ANCHOR-<prefix> via CBCentralManager) ---
        // Distinct from peer BLE (BCN-). An organizer in host anchor mode broadcasts
        // ANCHOR-<prefix> which attendee devices recognize as an event zone signal.
        let organizerAnchors = scanner.getKnownBeacons()
            .filter { device in
                device.name.hasPrefix("ANCHOR-")
                && device.rssi >= rssiThreshold
                && now.timeIntervalSince(device.lastSeen) < freshnessWindow
            }
            .sorted { $0.rssi > $1.rssi }

        let orgBest: (rssi: Int, source: String)? = organizerAnchors.first.map {
            (rssi: $0.rssi, source: "organizer:\($0.name)")
        }

        // --- Merge: pick the strongest signal from any path ---
        let candidates = [cbBest, clBest, orgBest].compactMap { $0 }
        let best = candidates.max(by: { $0.rssi < $1.rssi })

        // --- Update state ---
        if let anchor = best {
            isBeaconVisible = true
            lastBeaconSeenAt = now
            beaconConfidence = normalizeConfidence(rssi: anchor.rssi)
            currentZoneState = .inside
            anchorSource = anchor.source
        } else if let lastSeen = lastBeaconSeenAt,
                  now.timeIntervalSince(lastSeen) < signalLossGracePeriod {
            // Beacon was recently visible — within grace period.
            // Don't immediately flip to "outside" on brief signal drops.
            isBeaconVisible = false
            let elapsed = now.timeIntervalSince(lastSeen)
            let decay = max(0, 1.0 - (elapsed / signalLossGracePeriod))
            beaconConfidence = beaconConfidence * decay
            currentZoneState = .unknown
            // anchorSource stays as last known
        } else {
            // No beacon seen, or grace period expired.
            isBeaconVisible = false
            beaconConfidence = 0.0
            currentZoneState = .outside
            anchorSource = "none"
        }

        logStateIfChanged()
    }

    // MARK: - Confidence Normalization

    /// Maps raw RSSI to a 0.0–1.0 confidence value.
    /// -40 dBm (very close) → ~1.0, -80 dBm (threshold) → ~0.3
    private func normalizeConfidence(rssi: Int) -> Double {
        let clamped = Double(max(-90, min(-30, rssi)))
        // Linear mapping: -30 → 1.0, -90 → 0.0
        let normalized = (clamped + 90.0) / 60.0
        return max(0.0, min(1.0, normalized))
    }

    // MARK: - Public API (for downstream consumers)

    /// Whether the user is currently in or recently was in the beacon zone.
    /// Safe to call from any service — returns true for .inside or .unknown.
    var isInBeaconZone: Bool {
        currentZoneState == .inside || currentZoneState == .unknown
    }

    /// Resets all beacon state. Called on event leave or auth loss.
    func reset() {
        isBeaconVisible = false
        lastBeaconSeenAt = nil
        beaconConfidence = 0.0
        currentZoneState = .outside
        anchorSource = "none"
        lastLogSignature = ""
        #if DEBUG
        print("[BeaconPresence] Reset")
        #endif
    }

    // MARK: - Helpers

    /// CBCentralManager hardware anchor: device advertising with MOONSIDE in its BLE name.
    private func isCBHardwareAnchor(_ name: String) -> Bool {
        name.contains("MOONSIDE")
    }

    private func logStateIfChanged() {
        let sig = "\(currentZoneState.rawValue)|\(isBeaconVisible)|\(String(format: "%.2f", beaconConfidence))|\(anchorSource)"
        guard sig != lastLogSignature else { return }
        lastLogSignature = sig

        #if DEBUG
        print("[BeaconPresence] zone=\(currentZoneState.rawValue) visible=\(isBeaconVisible) confidence=\(String(format: "%.2f", beaconConfidence)) source=\(anchorSource) lastSeen=\(lastBeaconSeenAt?.formatted(date: .omitted, time: .standard) ?? "never")")
        #endif
    }
}
