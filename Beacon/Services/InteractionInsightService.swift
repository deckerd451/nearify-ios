import Foundation

// MARK: - Maslow Need State

enum NeedState: String {
    case belonging
    case esteem
    case selfActualization

    var icon: String {
        switch self {
        case .belonging:         return "person.wave.2"
        case .esteem:            return "star.circle"
        case .selfActualization: return "sparkles"
        }
    }

    var color: String {
        switch self {
        case .belonging:         return "orange"
        case .esteem:            return "purple"
        case .selfActualization: return "cyan"
        }
    }
}

// MARK: - Profile Insight

struct ProfileInsight: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let needState: NeedState
    let insightText: String
    let confidence: Double
    let score: Double
    let isConnected: Bool
    let hasMessaged: Bool
    let encounterMinutes: Int
    let sharedInterests: [String]
    let lastInteractionAt: Date?
}

// MARK: - Interaction Signal

struct InteractionSignal {
    let profileId: UUID
    let name: String
    var totalEncounterSeconds: Int = 0
    var encounterCount: Int = 0
    var lastSeenAt: Date?
    var isConnected: Bool = false
    var hasMessagedRecently: Bool = false
    var lastMessageAt: Date?
    var sharedInterests: [String] = []
    var viewerInterests: [String] = []
    var theirInterests: [String] = []
}

// MARK: - InteractionInsightService

@MainActor
final class InteractionInsightService {

    static let shared = InteractionInsightService()
    private init() {}

    // MARK: - Scoring Constants

    private enum Weight {
        static let encounterStrong: Double  = 25  // >= 15 min
        static let encounterMedium: Double  = 15  // >= 5 min
        static let encounterLight: Double   = 8   // >= 1 min
        static let recency10Min: Double     = 20
        static let recency1Hour: Double     = 12
        static let recency6Hour: Double     = 6
        static let connected: Double        = 10
        static let messagedRecently: Double = 20
        static let perSharedInterest: Double = 5
        static let maxInterestBoost: Double  = 20
    }

    // MARK: - Confidence Thresholds

    private enum Conf {
        static let realTime: Double = 0.5
        static let feed: Double     = 0.3
        static let minimum: Double  = 0.3  // Nothing below this is ever generated
    }

    // MARK: - Public API

    /// Generates exactly ONE insight per profileId from aggregated signals.
    /// Signals are first collapsed by profileId (keeping max values),
    /// then filtered by confidence, then one insight is produced per profile.
    func generateInsights(from signals: [InteractionSignal]) -> [ProfileInsight] {
        // Step 1: Aggregate signals by profileId — one stable signal per profile
        let aggregated = aggregateByProfile(signals)

        // Step 2: Generate one insight per aggregated signal, filtering weak ones
        var insights: [ProfileInsight] = []

        for signal in aggregated {
            let confidence = computeConfidence(signal)

            // Filter BEFORE generation — weak signals never produce insights
            guard confidence >= Conf.minimum else {
                #if DEBUG
                print("[Insight] Skip (conf=\(String(format: "%.2f", confidence)) < \(Conf.minimum)): \(signal.name)")
                #endif
                continue
            }

            let score = computeScore(signal)
            let needState = resolveNeedState(signal)
            let text = generateInsightText(signal: signal, needState: needState)

            let insight = ProfileInsight(
                profileId: signal.profileId,
                name: signal.name,
                needState: needState,
                insightText: text,
                confidence: confidence,
                score: score,
                isConnected: signal.isConnected,
                hasMessaged: signal.hasMessagedRecently,
                encounterMinutes: signal.totalEncounterSeconds / 60,
                sharedInterests: signal.sharedInterests,
                lastInteractionAt: signal.lastSeenAt ?? signal.lastMessageAt
            )

            #if DEBUG
            print("[Insight] FINAL \(signal.name): score=\(Int(score)) conf=\(String(format: "%.2f", confidence)) need=\(needState.rawValue) enc=\(signal.totalEncounterSeconds)s → \"\(text)\"")
            #endif

            insights.append(insight)
        }

        // Safety dedup (should be unnecessary after aggregation, but kept as guard)
        let bestPerProfile = Dictionary(grouping: insights, by: { $0.profileId })
            .compactMap { _, group in group.max(by: { $0.score < $1.score }) }

        #if DEBUG
        if bestPerProfile.count != insights.count {
            print("[Insight] ⚠️ Post-dedup: \(insights.count) → \(bestPerProfile.count) (aggregation missed a duplicate)")
        }
        #endif

        return bestPerProfile.sorted { $0.score > $1.score }
    }

    func realTimeInsights(from insights: [ProfileInsight]) -> [ProfileInsight] {
        insights.filter { $0.confidence >= Conf.realTime }
    }

    func feedInsights(from insights: [ProfileInsight]) -> [ProfileInsight] {
        insights.filter { $0.confidence >= Conf.feed }
    }

    // MARK: - Signal Aggregation (per-profile collapse)

    /// Collapses multiple signals for the same profileId into one stable signal.
    /// Uses MAX for encounter seconds, latest timestamps, union for interests.
    private func aggregateByProfile(_ signals: [InteractionSignal]) -> [InteractionSignal] {
        var map: [UUID: InteractionSignal] = [:]

        for signal in signals {
            if var existing = map[signal.profileId] {
                // Keep the MAX encounter time (stable, never decreasing)
                existing.totalEncounterSeconds = max(existing.totalEncounterSeconds, signal.totalEncounterSeconds)
                existing.encounterCount = max(existing.encounterCount, signal.encounterCount)

                // Keep the most recent timestamps
                if let newSeen = signal.lastSeenAt {
                    if let existingSeen = existing.lastSeenAt {
                        existing.lastSeenAt = max(existingSeen, newSeen)
                    } else {
                        existing.lastSeenAt = newSeen
                    }
                }
                if let newMsg = signal.lastMessageAt {
                    if let existingMsg = existing.lastMessageAt {
                        existing.lastMessageAt = max(existingMsg, newMsg)
                    } else {
                        existing.lastMessageAt = newMsg
                    }
                }

                // Union of relationship signals
                existing.isConnected = existing.isConnected || signal.isConnected
                existing.hasMessagedRecently = existing.hasMessagedRecently || signal.hasMessagedRecently

                // Union shared interests (deduplicated)
                let combined = Set(existing.sharedInterests).union(Set(signal.sharedInterests))
                existing.sharedInterests = Array(combined)

                map[signal.profileId] = existing
            } else {
                map[signal.profileId] = signal
            }
        }

        return Array(map.values)
    }

    // MARK: - Need State Resolution

    private func resolveNeedState(_ signal: InteractionSignal) -> NeedState {
        let hasDeepInteraction = signal.totalEncounterSeconds >= 300 && signal.hasMessagedRecently
        let hasSharedInterests = !signal.sharedInterests.isEmpty

        if hasSharedInterests && (hasDeepInteraction || signal.sharedInterests.count >= 3) {
            return .selfActualization
        }
        if signal.encounterCount >= 2 || signal.totalEncounterSeconds >= 600 || signal.isConnected {
            return .esteem
        }
        return .belonging
    }

    // MARK: - Insight Text Generation

    private func generateInsightText(signal: InteractionSignal, needState: NeedState) -> String {
        let name = signal.name.components(separatedBy: " ").first ?? signal.name
        let minutes = signal.totalEncounterSeconds / 60

        switch needState {
        case .belonging:
            if minutes > 0 && !signal.isConnected {
                return "You've been near \(name) for \(minutes) min — connect now"
            }
            if signal.isConnected && !signal.hasMessagedRecently {
                return "You're near \(name) — say hello"
            }
            return "You crossed paths with \(name) — reach out"

        case .esteem:
            if signal.hasMessagedRecently {
                return "\(name) is actively engaging with you at this event"
            }
            if signal.isConnected && minutes > 5 {
                return "\(name) is a strong match — you've spent \(minutes) min together"
            }
            if signal.encounterCount >= 2 {
                return "You keep running into \(name) — this could be meaningful"
            }
            return "\(name) is a strong match for you at this event"

        case .selfActualization:
            let interests = signal.sharedInterests.prefix(2).joined(separator: " & ")
            if !interests.isEmpty {
                return "You and \(name) share \(interests) — this could be valuable"
            }
            return "You and \(name) have deep alignment — explore the connection"
        }
    }

    // MARK: - Scoring (unified via InteractionScorer)

    private func computeScore(_ signal: InteractionSignal) -> Double {
        let signals = InteractionScorer.Signals(
            isBLEDetected: false, // insights are generated from aggregated data, not live BLE
            isHeartbeatLive: signal.lastSeenAt.map { Date().timeIntervalSince($0) < 60 } ?? false,
            encounterSeconds: signal.totalEncounterSeconds,
            historicalOverlapSeconds: 0,
            lastSeenAt: signal.lastSeenAt ?? signal.lastMessageAt,
            encounterCount: signal.encounterCount,
            isConnected: signal.isConnected,
            hasConversation: signal.hasMessagedRecently,
            sharedInterestCount: signal.sharedInterests.count
        )
        // Scale to existing range (~0–95) for compatibility with confidence thresholds
        return InteractionScorer.score(signals) * 95.0
    }

    private func computeConfidence(_ signal: InteractionSignal) -> Double {
        var factors: Double = 0
        let maxFactors: Double = 5

        if signal.totalEncounterSeconds >= 60 { factors += 1 }
        if signal.isConnected { factors += 1 }
        if signal.hasMessagedRecently { factors += 1 }
        if !signal.sharedInterests.isEmpty { factors += 1 }

        if let ts = signal.lastSeenAt ?? signal.lastMessageAt {
            let age = Date().timeIntervalSince(ts)
            if age < 600 { factors += 1 }
            else if age < 3600 { factors += 0.5 }
        }

        return min(factors / maxFactors, 1.0)
    }

    private func recencyBoost(for timestamp: Date?) -> Double {
        guard let ts = timestamp else { return 0 }
        let age = Date().timeIntervalSince(ts)
        if age < 600   { return Weight.recency10Min }
        if age < 3600  { return Weight.recency1Hour }
        if age < 21600 { return Weight.recency6Hour }
        return 0
    }

    // MARK: - Signal Builder

    func buildSignals(
        attendees: [EventAttendee],
        encounters: [UUID: Encounter],
        connectedIds: Set<UUID>,
        lastMessageTimes: [UUID: Date],
        viewerProfile: User?,
        myId: UUID
    ) -> [InteractionSignal] {
        let viewerInterests = Set(viewerProfile?.interests ?? [])

        return attendees.compactMap { attendee -> InteractionSignal? in
            guard attendee.id != myId else { return nil }

            let enc = encounters[attendee.id]
            let theirInterests = Set(attendee.interests ?? [])
            let shared = Array(viewerInterests.intersection(theirInterests))
            let msgTime = lastMessageTimes[attendee.id]
            let hasRecentMsg = msgTime.map { Date().timeIntervalSince($0) < 3600 } ?? false

            return InteractionSignal(
                profileId: attendee.id,
                name: attendee.name,
                totalEncounterSeconds: enc?.overlapSeconds ?? 0,
                encounterCount: enc != nil ? 1 : 0,
                lastSeenAt: enc?.lastSeenAt ?? attendee.lastSeen,
                isConnected: connectedIds.contains(attendee.id),
                hasMessagedRecently: hasRecentMsg,
                lastMessageAt: msgTime,
                sharedInterests: shared,
                viewerInterests: Array(viewerInterests),
                theirInterests: Array(theirInterests)
            )
        }
    }
}
