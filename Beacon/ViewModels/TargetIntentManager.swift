import Foundation
import Combine

/// System-wide source of truth for target intent.
/// Connects Home, People, and the attendee refresh loop.
///
/// Flow: set → resolving → found | notPresent → waiting → found | cleared
@MainActor
final class TargetIntentManager: ObservableObject {

    static let shared = TargetIntentManager()

    enum Resolution: Equatable {
        case resolving
        case found
        case notPresent
        case waiting
    }

    @Published private(set) var targetProfileId: UUID?
    @Published private(set) var targetName: String?
    @Published private(set) var setAt: Date?
    @Published private(set) var resolution: Resolution = .resolving

    let resolutionWindow: TimeInterval = 12

    private init() {}

    // MARK: - Public API

    var isActive: Bool { targetProfileId != nil }

    var targetFirstName: String {
        guard let name = targetName else { return "them" }
        return name.components(separatedBy: " ").first ?? name
    }

    var isResolutionWindowElapsed: Bool {
        guard let s = setAt else { return false }
        return Date().timeIntervalSince(s) > resolutionWindow
    }

    /// Sets a new target intent. Overwrites any previous intent cleanly.
    func set(profileId: UUID, name: String) {
        #if DEBUG
        if let prev = targetName, prev != name {
            print("[TargetIntent] switching target: \(prev) → \(name)")
        }
        print("[TargetIntent] set target: \(name)")
        #endif
        targetProfileId = profileId
        targetName = name
        setAt = Date()
        resolution = .resolving
    }

    /// Called by the attendee refresh loop when the target IS in the active list.
    func markFound() {
        guard isActive else { return }
        guard resolution != .found else { return } // no-op if already found

        let wasWaiting = resolution == .waiting
        resolution = .found

        #if DEBUG
        if wasWaiting {
            print("[TargetResolution] target appeared: \(targetName ?? "unknown")")
        } else {
            print("[TargetResolution] found")
        }
        #endif
    }

    /// Called by the attendee refresh loop when the target is NOT in the active list.
    func markNotPresent() {
        guard isActive else { return }

        switch resolution {
        case .resolving:
            // Only transition after the resolution window
            if isResolutionWindowElapsed {
                resolution = .notPresent
                #if DEBUG
                print("[TargetResolution] not present")
                #endif
            }

        case .found:
            // Target left the event — go back to notPresent
            resolution = .notPresent
            #if DEBUG
            print("[TargetResolution] target left → not present")
            #endif

        case .waiting:
            // Keep waiting — no state change, just log periodically
            break

        case .notPresent:
            break // already there
        }
    }

    /// User chose "Keep Watching" — continue background evaluation.
    func markWaiting() {
        guard isActive else { return }
        resolution = .waiting
        #if DEBUG
        print("[TargetResolution] waiting")
        print("[TargetIntent] keep watching enabled for \(targetName ?? "unknown")")
        #endif
    }

    /// Clears the intent entirely. UI returns to normal.
    func clear(reason: String) {
        #if DEBUG
        print("[TargetIntent] cleared (\(reason))")
        #endif
        targetProfileId = nil
        targetName = nil
        setAt = nil
        resolution = .resolving
    }
}
