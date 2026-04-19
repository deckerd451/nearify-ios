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
                #if DEBUG
                print("[BLE-ADV] Bluetooth powered on")
                #endif
                if communityId != nil {
                    startAdvertising()
                }
            case .poweredOff:
                print("[BLE-ADV] ⚠️ Bluetooth powered off")
                stopAdvertising()
            case .unauthorized:
                print("[BLE-ADV] ⚠️ Bluetooth unauthorized")
                stopAdvertising()
            default:
                print("[BLE-ADV] ⚠️ Bluetooth unavailable")
                stopAdvertising()
            }
        }
    }
    
    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[BLE-ADV] ❌ Failed to start advertising: \(error)")
                print("[BLE-ADV]   Error domain: \((error as NSError).domain), code: \((error as NSError).code)")
                isAdvertising = false
                
                // Retry once after a short delay if we still have a community ID to advertise
                if self.communityId != nil {
                    print("[BLE-ADV]   🔄 Will retry in 2s...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !self.isAdvertising && self.communityId != nil {
                        self.startAdvertising()
                    }
                }
            } else {
                isAdvertising = true
                #if DEBUG
                print("[BLE-ADV] ✅ Advertising confirmed by CoreBluetooth")
                print("[BLE-ADV]   Advertised prefix: \(self.advertisedCommunityPrefix ?? "none")")
                print("[BLE-ADV]   isAdvertising (manager): \(peripheral.isAdvertising)")
                #endif
            }
        }
    }
    
    // MARK: - Public API
    
    /// Start advertising with the user's community ID embedded in the local name.
    /// Format: "BCN-<first-8-chars-of-community-uuid>"
    /// This allows other attendees' scanners to resolve the BLE signal to a profile.
    func startAdvertisingForEvent(communityId: UUID) {
        let targetPrefix = String(communityId.uuidString.prefix(8)).lowercased()
        #if DEBUG
        print("[BLE-ADV] 🎫 startAdvertisingForEvent called")
        print("[BLE-ADV]   Community ID: \(communityId)")
        print("[BLE-ADV]   Target prefix: BCN-\(targetPrefix)")
        print("[BLE-ADV]   Current prefix: \(advertisedCommunityPrefix ?? "none")")
        print("[BLE-ADV]   isAdvertising: \(isAdvertising)")
        print("[BLE-ADV]   BT state: \(peripheralManager.state.rawValue)")
        #endif
        
        // If already advertising with the correct prefix, skip entirely.
        // This prevents the stop/restart race that leaves the advertiser inactive.
        if isAdvertising && advertisedCommunityPrefix == targetPrefix {
            #if DEBUG
            print("[BLE-ADV]   ✅ Already advertising correct prefix — skipping restart")
            #endif
            return
        }
        
        // Store community ID — peripheralManagerDidUpdateState will
        // call startAdvertising() when BT becomes ready if it isn't already.
        self.communityId = communityId
        
        // Need to (re)start: either not advertising, or advertising wrong prefix.
        let needsRestart = peripheralManager.isAdvertising
        if needsRestart {
            #if DEBUG
            print("[BLE-ADV]   🔄 Advertising wrong prefix — stopping to restart with identity")
            #endif
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
            #if DEBUG
            print("[BLE-ADV]   ⏳ BT not powered on (state: \(peripheralManager.state.rawValue)) — will start when ready")
            #endif
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
            #if DEBUG
            print("[BLE-ADV] ⚠️ Cannot enable host anchor — not joined to event")
            #endif
            return
        }
        guard !isHostAnchorMode else { return }

        isHostAnchorMode = true
        restartAdvertising()

        #if DEBUG
        print("[BLE-ADV] 🏠 Host Anchor Mode ENABLED")
        #endif
    }

    func disableHostAnchorMode() {
        guard isHostAnchorMode else { return }

        isHostAnchorMode = false
        restartAdvertising()

        #if DEBUG
        print("[BLE-ADV] 🏠 Host Anchor Mode DISABLED — back to attendee mode")
        #endif
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
            #if DEBUG
            print("[BLE-ADV] Already advertising (prefix: \(advertisedCommunityPrefix ?? "legacy"))")
            #endif
            return
        }
        
        guard peripheralManager.state == .poweredOn else {
            #if DEBUG
            print("[BLE-ADV] ⏳ Bluetooth not ready, will start when powered on")
            #endif
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
            print("[BLE-ADV] ⚠️⚠️⚠️ LEGACY MODE — no community ID available")
            print("[BLE-ADV] ⚠️ This device will NOT be resolvable to an attendee profile")
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        isAdvertising = true
        
        #if DEBUG
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[BLE-ADV] 📡 Started advertising")
        print("  Mode: \(isLegacy ? "⚠️ LEGACY" : isHostAnchorMode ? "🏠 HOST ANCHOR" : "✅ IDENTITY")")
        print("  Local Name: \(localName)")
        print("  Full Community ID: \(communityId?.uuidString ?? "none")")
        print("  Advertised Prefix: \(advertisedCommunityPrefix ?? "none")")
        print("  Service UUID: \(serviceUUID.uuidString)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        #endif
    }
    
    /// Force-start advertising, bypassing the `isAdvertising` guard.
    /// Used after a stop+restart where CoreBluetooth may still report isAdvertising=true briefly.
    private func forceStartAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            #if DEBUG
            print("[BLE-ADV] ⏳ Bluetooth not ready for force-start, will start when powered on")
            #endif
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
            print("[BLE-ADV] ⚠️⚠️⚠️ LEGACY MODE — no community ID available")
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        isAdvertising = true
        
        #if DEBUG
        print("[BLE-ADV] 📡 Force-started advertising (mode: \(isLegacy ? "LEGACY" : isHostAnchorMode ? "HOST ANCHOR" : "IDENTITY"), name: \(localName))")
        #endif
    }
    
    func stopAdvertising() {
        guard peripheralManager.isAdvertising else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        #if DEBUG
        print("[BLE-ADV] 🛑 Stopped advertising")
        #endif
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
