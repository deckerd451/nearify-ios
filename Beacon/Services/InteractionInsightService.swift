import Foundation

// MARK: - Maslow Need State

/// Maps interaction signals to human needs (Maslow's Hierarchy).
/// Each profile gets exactly ONE primary need state — the strongest applicable.
enum NeedState: String {
    case belonging          // strong proximity, not connected, recent encounter
    case esteem             // repeated encounters, high confidence, high interaction score
    case selfActualization  // shared interests, meaningful alignment, deep interaction

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

/// A single, human-level insight for one profile.
/// Specific, actionable, time-relevant. Never generic.
struct ProfileInsight: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let needState: NeedState
    let insightText: String       // The human-readable insight
    let confidence: Double        // 0.0–1.0, controls visibility thresholds
    let score: Double             // Composite score for ranking
    let isConnected: Bool
    let hasMessaged: Bool
    let encounterMinutes: Int
    let sharedInterests: [String]
    let lastInteractionAt: Date?
}

// MARK: - Interaction Signal (per-profile aggregation)

/// Aggregated signals for one profile at one event. Computed in-memory.
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

/// Interprets raw signals → maps to Maslow need states → generates human-level insights.
/// Pure computation layer. No database tables. No persistence.
@MainActor
final class InteractionInsightService {

    static let shared = InteractionInsightService()
    private init() {}

    // MARK: - Scoring Constants

    private enum Weight {
        // Encounter
        static let encounterStrong: Double  = 25  // >= 15 min
        static let encounterMedium: Double  = 15  // >= 5 min
        static let encounterLight: Double   = 8   // >= 1 min

        // Recency
        static let recency10Min: Double     = 20
        static let recency1Hour: Double     = 12
        static let recency6Hour: Double     = 6

        // Relationship
        static let connected: Double        = 10
        static let messagedRecently: Double = 20

        // Shared interests
        static let perSharedInterest: Double = 5
        static let maxInterestBoost: Double  = 20
    }

    // MARK: - Confidence Thresholds

    private enum Confidence {
        static let realTime: Double = 0.6   // Show in Event tab
        static let feed: Double     = 0.3   // Show in Feed
        static let minimum: Double  = 0.15  // Below this, suppress entirely
    }

    // MARK: - Public API

    /// Generates insights for all profiles from aggregated signals.
    /// Returns sorted by score DESC, one insight per profile, strongest need state only.
    func generateInsights(from signals: [InteractionSignal]) -> [ProfileInsight] {
        var insights: [ProfileInsight] = []

        for signal in signals {
            let score = computeScore(signal)
            let confidence = computeConfidence(signal)

            guard confidence >= Confidence.minimum else {
                #if DEBUG
                print("[Insight] Skip (low confidence): \(signal.name) conf=\(String(format: "%.2f", confidence))")
                #endif
                continue
            }

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
            print("[Insight] \(signal.name): need=\(needState.rawValue) score=\(Int(score)) conf=\(String(format: "%.2f", confidence)) → \"\(text)\"")
            #endif

            insights.append(insight)
        }

        // Deduplicate: one best insight per profileId
        let bestPerProfile = Dictionary(grouping: insights, by: { $0.profileId })
            .compactMap { _, group in
                group.max(by: { $0.score < $1.score })
            }

        #if DEBUG
        print("[Insight] Deduped \(insights.count) → \(bestPerProfile.count) profiles")
        #endif

        return bestPerProfile.sorted { $0.score > $1.score }
    }

    /// Filters insights for real-time display (Event tab).
    /// Only high-confidence, recent signals.
    func realTimeInsights(from insights: [ProfileInsight]) -> [ProfileInsight] {
        insights.filter { $0.confidence >= Confidence.realTime }
    }

    /// Filters insights for feed display.
    func feedInsights(from insights: [ProfileInsight]) -> [ProfileInsight] {
        insights.filter { $0.confidence >= Confidence.feed }
    }

    // MARK: - Need State Resolution

    /// Assigns exactly ONE primary need state per profile.
    /// Priority: selfActualization > esteem > belonging
    private func resolveNeedState(_ signal: InteractionSignal) -> NeedState {
        let hasDeepInteraction = signal.totalEncounterSeconds >= 300 && signal.hasMessagedRecently
        let hasSharedInterests = !signal.sharedInterests.isEmpty

        // Self-actualization: shared interests + meaningful interaction depth
        if hasSharedInterests && (hasDeepInteraction || signal.sharedInterests.count >= 3) {
            return .selfActualization
        }

        // Esteem: repeated/strong encounters, high confidence match
        if signal.encounterCount >= 2 || signal.totalEncounterSeconds >= 600 || signal.isConnected {
            return .esteem
        }

        // Belonging: proximity-based, not yet connected
        return .belonging
    }

    // MARK: - Insight Text Generation

    /// Generates specific, actionable, time-relevant text. Never generic.
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

    // MARK: - Scoring

    private func computeScore(_ signal: InteractionSignal) -> Double {
        var total: Double = 0

        // Encounter strength
        let secs = signal.totalEncounterSeconds
        if secs >= 900      { total += Weight.encounterStrong }
        else if secs >= 300 { total += Weight.encounterMedium }
        else if secs >= 60  { total += Weight.encounterLight }

        // Recency
        total += recencyBoost(for: signal.lastSeenAt ?? signal.lastMessageAt)

        // Relationship
        if signal.isConnected { total += Weight.connected }
        if signal.hasMessagedRecently { total += Weight.messagedRecently }

        // Shared interests
        let interestBoost = min(
            Double(signal.sharedInterests.count) * Weight.perSharedInterest,
            Weight.maxInterestBoost
        )
        total += interestBoost

        return total
    }

    private func computeConfidence(_ signal: InteractionSignal) -> Double {
        var factors: Double = 0
        let maxFactors: Double = 5

        if signal.totalEncounterSeconds >= 60 { factors += 1 }
        if signal.isConnected { factors += 1 }
        if signal.hasMessagedRecently { factors += 1 }
        if !signal.sharedInterests.isEmpty { factors += 1 }

        // Recency factor
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

    // MARK: - Signal Aggregation Helper

    /// Builds InteractionSignals from existing service data.
    /// Call this to bridge existing EventIntelligenceService data into the insight layer.
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

            let signal = InteractionSignal(
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

            return signal
        }
    }
}
