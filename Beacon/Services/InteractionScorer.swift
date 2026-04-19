import Foundation

// MARK: - Unified Interaction Score
//
// Single scoring function used by ALL recommendation surfaces.
// Replaces 7 independent scoring systems with one consistent formula.
//
// interactionScore(person) =
//     0.35 × proximityScore      (BLE + heartbeat presence)
//   + 0.30 × durationScore       (encounter dwell time, capped at 10 min)
//   + 0.15 × recencyScore        (how recently seen: 5 min / 30 min / 2 hr)
//   + 0.10 × repeatScore         (repeat encounters, capped at 3)
//   + 0.10 × relationshipScore   (connection + messaging + shared interests)
//
// Output: 0.0 – 1.0 (normalized)

@MainActor
enum InteractionScorer {

    // MARK: - Weights

    private enum W {
        static let proximity:    Double = 0.35
        static let duration:     Double = 0.30
        static let recency:      Double = 0.15
        static let repeats:      Double = 0.10
        static let relationship: Double = 0.10
    }

    // MARK: - Caps

    private enum Cap {
        static let durationSeconds: Double = 600   // 10 minutes
        static let repeatEncounters: Double = 3.0
    }

    // MARK: - Input

    /// All signals needed to score a person. Gathered once, passed to `score()`.
    struct Signals {
        // Proximity
        let isBLEDetected: Bool
        let isHeartbeatLive: Bool       // Supabase heartbeat < 60s

        // Duration
        let encounterSeconds: Int       // session BLE dwell time
        let historicalOverlapSeconds: Int // from RelationshipMemory

        // Recency
        let lastSeenAt: Date?           // most recent encounter/presence timestamp

        // Repeats
        let encounterCount: Int         // distinct encounter sessions

        // Relationship
        let isConnected: Bool
        let hasConversation: Bool
        let sharedInterestCount: Int

        init(
            isBLEDetected: Bool = false,
            isHeartbeatLive: Bool = false,
            encounterSeconds: Int = 0,
            historicalOverlapSeconds: Int = 0,
            lastSeenAt: Date? = nil,
            encounterCount: Int = 0,
            isConnected: Bool = false,
            hasConversation: Bool = false,
            sharedInterestCount: Int = 0
        ) {
            self.isBLEDetected = isBLEDetected
            self.isHeartbeatLive = isHeartbeatLive
            self.encounterSeconds = encounterSeconds
            self.historicalOverlapSeconds = historicalOverlapSeconds
            self.lastSeenAt = lastSeenAt
            self.encounterCount = encounterCount
            self.isConnected = isConnected
            self.hasConversation = hasConversation
            self.sharedInterestCount = sharedInterestCount
        }
    }

    // MARK: - Score

    /// Returns a normalized score in [0.0, 1.0].
    static func score(_ s: Signals) -> Double {
        let p = proximityScore(s)
        let d = durationScore(s)
        let r = recencyScore(s)
        let rp = repeatScore(s)
        let rel = relationshipScore(s)

        let total = W.proximity * p
                  + W.duration * d
                  + W.recency * r
                  + W.repeats * rp
                  + W.relationship * rel

        return min(max(total, 0.0), 1.0)
    }

    // MARK: - Sub-Scores (all 0.0 – 1.0)

    /// BLE detection is strongest (1.0), heartbeat-only is moderate (0.6),
    /// both together is full confidence (1.0), neither is 0.
    static func proximityScore(_ s: Signals) -> Double {
        if s.isBLEDetected { return 1.0 }
        if s.isHeartbeatLive { return 0.6 }
        return 0.0
    }

    /// Encounter dwell time normalized to 10-minute cap.
    /// Uses the greater of session BLE time and historical overlap.
    static func durationScore(_ s: Signals) -> Double {
        let effectiveSeconds = Double(max(s.encounterSeconds, s.historicalOverlapSeconds))
        return min(effectiveSeconds / Cap.durationSeconds, 1.0)
    }

    /// Recency buckets: <5 min = 1.0, <30 min = 0.7, <2 hr = 0.4, older = 0.1, none = 0.
    static func recencyScore(_ s: Signals) -> Double {
        guard let lastSeen = s.lastSeenAt else { return 0.0 }
        let age = Date().timeIntervalSince(lastSeen)
        if age < 300   { return 1.0 }   // < 5 min
        if age < 1800  { return 0.7 }   // < 30 min
        if age < 7200  { return 0.4 }   // < 2 hr
        return 0.1
    }

    /// Repeat encounters normalized to cap of 3.
    static func repeatScore(_ s: Signals) -> Double {
        return min(Double(s.encounterCount) / Cap.repeatEncounters, 1.0)
    }

    /// Relationship signals: connection (0.4) + conversation (0.3) + interests (up to 0.3).
    static func relationshipScore(_ s: Signals) -> Double {
        var r: Double = 0
        if s.isConnected { r += 0.4 }
        if s.hasConversation { r += 0.3 }
        r += min(Double(s.sharedInterestCount) * 0.1, 0.3)
        return min(r, 1.0)
    }

    // MARK: - Convenience Builders

    /// Build signals from a live EventAttendee + encounter tracker.
    static func signals(
        for attendee: EventAttendee,
        encounter: EncounterTracker?,
        bleDetected: Bool,
        connectedIds: Set<UUID>,
        myInterests: Set<String> = []
    ) -> Signals {
        let theirInterests = Set((attendee.interests ?? []).map { $0.lowercased() })
        let shared = myInterests.intersection(theirInterests)

        return Signals(
            isBLEDetected: bleDetected,
            isHeartbeatLive: attendee.isHereNow,
            encounterSeconds: encounter?.totalSeconds ?? 0,
            historicalOverlapSeconds: 0,
            lastSeenAt: encounter?.lastSeen ?? attendee.lastSeen,
            encounterCount: encounter != nil ? 1 : 0,
            isConnected: connectedIds.contains(attendee.id),
            hasConversation: false,
            sharedInterestCount: shared.count
        )
    }

    /// Build signals from a RelationshipMemory + optional live encounter.
    static func signals(
        for rel: RelationshipMemory,
        encounter: EncounterTracker?,
        bleDetected: Bool,
        heartbeatLive: Bool,
        myInterests: Set<String> = []
    ) -> Signals {
        
        // sharedInterests on RelationshipMemory is already the intersection
        let sharedCount = rel.sharedInterests.count

        return Signals(
            isBLEDetected: bleDetected,
            isHeartbeatLive: heartbeatLive,
            encounterSeconds: encounter?.totalSeconds ?? 0,
            historicalOverlapSeconds: rel.totalOverlapSeconds,
            lastSeenAt: encounter?.lastSeen ?? rel.lastEncounterAt,
            encounterCount: rel.encounterCount,
            isConnected: rel.connectionStatus == .accepted,
            hasConversation: rel.hasConversation,
            sharedInterestCount: sharedCount
        )
    }
}
