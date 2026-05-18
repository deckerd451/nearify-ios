import Foundation
import CoreBluetooth
import Combine
import UIKit

// MARK: - BLE Advertiser Service

@MainActor
final class BLEAdvertiserService: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    
    static let shared = BLEAdvertiserService()
    
    @Published private(set) var isAdvertising = false
    
    /// The community ID prefix currently being advertised (first 8 chars of UUID)
    @Published private(set) var advertisedCommunityPrefix: String?

    /// Whether this device is broadcasting as a host anchor for the event.
    /// When true, advertises as ANCHOR-<prefix> instead of BCN-<prefix>.
    @Published private(set) var isHostAnchorMode: Bool = false
    
    private var peripheralManager: CBPeripheralManager!
    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    
    /// The community ID to embed in the BLE advertisement.
    /// Set by EventJoinService when joining an event.
    private var communityId: UUID?
    
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                DebugLog.verbose("[BLE-ADV] Bluetooth powered on")
                if communityId != nil {
                    startAdvertising()
                }
            case .poweredOff:
                DebugLog.diagnostic("[BLESession] Bluetooth powered off")
                stopAdvertising()
            case .unauthorized:
                DebugLog.diagnostic("[BLESession] Bluetooth unauthorized")
                stopAdvertising()
            default:
                DebugLog.diagnostic("[BLESession] Bluetooth unavailable")
                stopAdvertising()
            }
        }
    }
    
    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error = error {
                DebugLog.diagnostic("[BLESession] failed to start advertising: \(error)")
                DebugLog.verbose("[BLESession] advertising error domain=\((error as NSError).domain) code=\((error as NSError).code)")
                isAdvertising = false
                
                // Retry once after a short delay if we still have a community ID to advertise
                if self.communityId != nil {
                    DebugLog.verbose("[BLESession] advertising retry scheduled in 2s")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !self.isAdvertising && self.communityId != nil {
                        self.startAdvertising()
                    }
                }
            } else {
                isAdvertising = true
                DebugLog.verbose("[BLE-ADV] ✅ Advertising confirmed by CoreBluetooth")
                DebugLog.verbose("[BLE-ADV]   Advertised prefix: \(self.advertisedCommunityPrefix ?? "none")")
                DebugLog.verbose("[BLE-ADV]   isAdvertising (manager): \(peripheral.isAdvertising)")
            }
        }
    }
    
    // MARK: - Public API
    
    /// Start advertising with the user's community ID embedded in the local name.
    /// Format: "BCN-<first-8-chars-of-community-uuid>"
    /// This allows other attendees' scanners to resolve the BLE signal to a profile.
    func startAdvertisingForEvent(communityId: UUID) {
        let targetPrefix = String(communityId.uuidString.prefix(8)).lowercased()
        DebugLog.verbose("[BLE-ADV] 🎫 startAdvertisingForEvent called")
        DebugLog.verbose("[BLE-ADV]   Community ID: \(communityId)")
        DebugLog.verbose("[BLE-ADV]   Target prefix: BCN-\(targetPrefix)")
        DebugLog.verbose("[BLE-ADV]   Current prefix: \(advertisedCommunityPrefix ?? "none")")
        DebugLog.verbose("[BLE-ADV]   isAdvertising: \(isAdvertising)")
        DebugLog.verbose("[BLE-ADV]   BT state: \(peripheralManager.state.rawValue)")
        
        // If already advertising with the correct prefix, skip entirely.
        // This prevents the stop/restart race that leaves the advertiser inactive.
        if isAdvertising && advertisedCommunityPrefix == targetPrefix {
            DebugLog.verbose("[BLE-ADV]   ✅ Already advertising correct prefix — skipping restart")
            return
        }
        
        // Store community ID — peripheralManagerDidUpdateState will
        // call startAdvertising() when BT becomes ready if it isn't already.
        self.communityId = communityId
        
        // Need to (re)start: either not advertising, or advertising wrong prefix.
        let needsRestart = peripheralManager.isAdvertising
        if needsRestart {
            DebugLog.verbose("[BLE-ADV]   🔄 Advertising wrong prefix — stopping to restart with identity")
            peripheralManager.stopAdvertising()
            isAdvertising = false
            advertisedCommunityPrefix = nil
        }
        
        if peripheralManager.state == .poweredOn {
            // After a stop, CoreBluetooth may still report isAdvertising=true briefly.
            // Call forceStartAdvertising to bypass the isAdvertising guard.
            if needsRestart {
                forceStartAdvertising()
            } else {
                startAdvertising()
            }
        } else {
            DebugLog.verbose("[BLE-ADV]   ⏳ BT not powered on (state: \(peripheralManager.state.rawValue)) — will start when ready")
        }
    }
    
    /// Stop event-scoped advertising and clear identity.
    func stopEventAdvertising() {
        communityId = nil
        advertisedCommunityPrefix = nil
        isHostAnchorMode = false
        stopAdvertising()
    }

    // MARK: - Host Anchor Mode
    //
    // Allows an organizer's phone to act as the event anchor beacon.
    // When enabled, the BLE local name changes from BCN-<prefix> to ANCHOR-<prefix>.
    // Attendee devices recognize ANCHOR- as an event zone signal, distinct from
    // normal peer BLE (BCN-). This replaces the need for dedicated hardware beacons.
    //
    // RULES:
    //   - Only available while joined to an event (communityId must be set).
    //   - Toggling restarts advertising with the new prefix.
    //   - Does not affect the organizer's own event participation state.

    func enableHostAnchorMode() {
        guard communityId != nil else {
            DebugLog.verbose("[BLE-ADV] ⚠️ Cannot enable host anchor — not joined to event")
            return
        }
        guard !isHostAnchorMode else { return }

        isHostAnchorMode = true
        restartAdvertising()

        DebugLog.verbose("[BLE-ADV] 🏠 Host Anchor Mode ENABLED")
    }

    func disableHostAnchorMode() {
        guard isHostAnchorMode else { return }

        isHostAnchorMode = false
        restartAdvertising()

        DebugLog.verbose("[BLE-ADV] 🏠 Host Anchor Mode DISABLED — back to attendee mode")
    }

    /// Restarts advertising with current mode (anchor vs attendee).
    private func restartAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
            isAdvertising = false
        }
        forceStartAdvertising()
    }
    
    // MARK: - Advertising Control
    
    func startAdvertising() {
        guard !peripheralManager.isAdvertising else {
            DebugLog.verbose("[BLE-ADV] Already advertising (prefix: \(advertisedCommunityPrefix ?? "legacy"))")
            return
        }
        
        guard peripheralManager.state == .poweredOn else {
            DebugLog.verbose("[BLE-ADV] ⏳ Bluetooth not ready, will start when powered on")
            return
        }
        
        // Build local name with community ID prefix for identity resolution.
        // Host anchor mode: "ANCHOR-<prefix>" — recognized as event zone signal.
        // Normal attendee mode: "BCN-<prefix>" — recognized as peer BLE.
        let localName: String
        let isLegacy: Bool
        if let cid = communityId {
            let prefix = String(cid.uuidString.prefix(8)).lowercased()
            if isHostAnchorMode {
                localName = "ANCHOR-\(prefix)"
            } else {
                localName = "BCN-\(prefix)"
            }
            advertisedCommunityPrefix = prefix
            isLegacy = false
        } else {
            // Fallback: legacy format — log loudly
            localName = "BEACON-\(UIDevice.current.name)"
            advertisedCommunityPrefix = nil
            isLegacy = true
            DebugLog.diagnostic("[BLESession] legacy advertising without community ID")
            DebugLog.diagnostic("[BLESession] advertiser is not resolvable to attendee profile")
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        isAdvertising = true
        
        DebugLog.verbose("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        DebugLog.verbose("[BLE-ADV] 📡 Started advertising")
        DebugLog.verbose("  Mode: \(isLegacy ? "⚠️ LEGACY" : isHostAnchorMode ? "🏠 HOST ANCHOR" : "✅ IDENTITY")")
        DebugLog.verbose("  Local Name: \(localName)")
        DebugLog.verbose("  Full Community ID: \(communityId?.uuidString ?? "none")")
        DebugLog.verbose("  Advertised Prefix: \(advertisedCommunityPrefix ?? "none")")
        DebugLog.verbose("  Service UUID: \(serviceUUID.uuidString)")
        DebugLog.verbose("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// Force-start advertising, bypassing the `isAdvertising` guard.
    /// Used after a stop+restart where CoreBluetooth may still report isAdvertising=true briefly.
    private func forceStartAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            DebugLog.verbose("[BLE-ADV] ⏳ Bluetooth not ready for force-start, will start when powered on")
            return
        }
        
        let localName: String
        let isLegacy: Bool
        if let cid = communityId {
            let prefix = String(cid.uuidString.prefix(8)).lowercased()
            if isHostAnchorMode {
                localName = "ANCHOR-\(prefix)"
            } else {
                localName = "BCN-\(prefix)"
            }
            advertisedCommunityPrefix = prefix
            isLegacy = false
        } else {
            localName = "BEACON-\(UIDevice.current.name)"
            advertisedCommunityPrefix = nil
            isLegacy = true
            DebugLog.diagnostic("[BLESession] legacy advertising without community ID")
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        isAdvertising = true
        
        DebugLog.verbose("[BLE-ADV] 📡 Force-started advertising (mode: \(isLegacy ? "LEGACY" : isHostAnchorMode ? "HOST ANCHOR" : "IDENTITY"), name: \(localName))")
    }
    
    func stopAdvertising() {
        guard peripheralManager.isAdvertising else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        DebugLog.verbose("[BLE-ADV] 🛑 Stopped advertising")
    }
    
    // MARK: - Parsing Helpers
    
    /// Extracts the community ID prefix from a BLE device name.
    /// Returns the 8-char hex prefix if the name matches "BCN-<prefix>", nil otherwise.
    static func parseCommunityPrefix(from deviceName: String) -> String? {
        guard deviceName.hasPrefix("BCN-") else { return nil }
        let prefix = deviceName.replacingOccurrences(of: "BCN-", with: "").lowercased()
        guard prefix.count == 8 else { return nil }
        return prefix
    }

    /// Extracts the community ID prefix from an organizer anchor device name.
    /// Returns the 8-char hex prefix if the name matches "ANCHOR-<prefix>", nil otherwise.
    static func parseAnchorPrefix(from deviceName: String) -> String? {
        guard deviceName.hasPrefix("ANCHOR-") else { return nil }
        let prefix = deviceName.replacingOccurrences(of: "ANCHOR-", with: "").lowercased()
        guard prefix.count == 8 else { return nil }
        return prefix
    }
}
