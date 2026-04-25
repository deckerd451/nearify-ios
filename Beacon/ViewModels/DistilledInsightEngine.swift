import Foundation

/// Generates a single human-readable insight line per person.
/// Strict priority cascade — only one rule fires.
/// No numbers, no scores, no stacking.
@MainActor
struct DistilledInsightEngine {

    /// Input signals for insight generation.
    struct Signals {
        let isHereNow: Bool
        let isTargetIntent: Bool
        let targetResolution: TargetIntentManager.Resolution
        let encounterDurationSeconds: Int   // current live encounter
        let totalOverlapSeconds: Int        // cumulative across sessions
        let encounterCount: Int
        let connectionStatus: RelationshipConnectionStatus
        let hasMessaged: Bool
        let needsFollowUp: Bool
        let sharedInterests: [String]
        let lastSeenEventName: String?
    }

    /// Returns exactly one distilled insight line.
    static func generate(signals s: Signals) -> String {

        // ── LEVEL 1: TARGET INTENT (highest priority) ──

        if s.isTargetIntent {
            switch s.targetResolution {
            case .notPresent:
                return "Not here right now · You were looking for them"
            case .waiting:
                return "Watching for them to arrive"
            case .found:
                return "Here now · You were looking for them"
            case .resolving:
                if s.isHereNow {
                    return "Here now · You were looking for them"
                }
                return "Looking for them now"
            }
        }

        // ── LEVEL 2: LIVE PRESENCE ──

        if s.isHereNow {
            if s.encounterDurationSeconds > 600 {
                return "Here now · You spent meaningful time together"
            }
            if s.encounterDurationSeconds > 120 {
                return "Here now · You were just near each other"
            }
            return "Here now"
        }

        // ── LEVEL 3: STRONG RECENT INTERACTION ──

        if s.totalOverlapSeconds > 600 {
            return "Met — meaningful interaction"
        }
        if s.totalOverlapSeconds > 120 {
            return "Crossed paths — brief interaction"
        }

        // ── LEVEL 4: FOLLOW-UP GAP ──

        if s.connectionStatus == .accepted && !s.hasMessaged {
            return "You connected but haven't followed up"
        }
        if s.needsFollowUp && !s.hasMessaged {
            return "You met but didn't follow up"
        }
        if s.needsFollowUp && s.hasMessaged {
            return "You haven't talked in a while"
        }

        // ── LEVEL 5: SHARED CONTEXT ──

        if !s.sharedInterests.isEmpty {
            let topics = s.sharedInterests.prefix(2).joined(separator: " and ")
            return "You share interests in \(topics)"
        }

        // ── LEVEL 6: FALLBACK ──

        if let event = s.lastSeenEventName {
            return "Seen at \(event)"
        }

        return "Met — meaningful interaction"
    }
}
