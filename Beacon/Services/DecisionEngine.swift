import Foundation

// MARK: - Decision Output

/// The single output for one candidate. One action, one reason, one tier.
struct SurfaceDecision: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let tier: DecisionTier
    let action: SurfaceAction
    let reason: String          // Factual, explainable. Never vague.
    let signals: DecisionSignals // Debug transparency
}

enum DecisionTier: Int, Comparable {
    case activeConversation = 1
    case strongInteraction  = 2
    case breakthroughPotential = 3
    case repeatedNearMiss   = 4
    case followUpGap        = 5

    static func < (lhs: DecisionTier, rhs: DecisionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .activeConversation:    return "Active Conversation"
        case .strongInteraction:     return "Strong Interaction"
        case .breakthroughPotential: return "Breakthrough Potential"
        case .repeatedNearMiss:      return "Repeated Near-Miss"
        case .followUpGap:           return "Follow-up Gap"
        }
    }
}

enum SurfaceAction: String {
    case message    = "Message"
    case connect    = "Connect"
    case viewProfile = "View Profile"
}

/// Raw signals used for the decision — exposed for debug logging.
struct DecisionSignals {
    let interactionScore: Double
    let potentialScore: Double
    let impactScore: Double
    let timingScore: Double
    let encounterSeconds: Int
    let encounterCount: Int
    let isConnected: Bool
    let hasRecentMessage: Bool
    let sharedInterests: [String]
}

// MARK: - Candidate Input

/// Everything the engine needs to decide about one person.
/// Built from existing InteractionSignal + attendee data.
struct DecisionCandidate {
    let profileId: UUID
    let name: String

    // Interaction layer
    let totalEncounterSeconds: Int
    let encounterCount: Int
    let isConnected: Bool
    let hasRecentMessage: Bool
    let lastMessageAge: TimeInterval?   // seconds since last message
    let lastSeenAge: TimeInterval?      // seconds since last encounter/presence

    // Potential layer
    let sharedInterests: [String]
    let viewerInterests: [String]
    let theirInterests: [String]

    // Readiness (both users active at event)
    let viewerIsActive: Bool
    let candidateIsActive: Bool
}

// MARK: - Decision Engine

/// Decision-first intelligence. NOT a scoring engine.
/// Uses hard thresholds, gating conditions, and tiered decision logic.
/// Scores are for threshold comparison only — never combined into a weighted average.
@MainActor
final class DecisionEngine {

    static let shared = DecisionEngine()
    private init() {}

    // MARK: - Tunable Thresholds (versioned, manual adjustment only)

    private enum Gate {
        // Timing
        static let timingMinForTier2: Double = 0.6
        static let timingMinForTier3: Double = 0.7
        static let timingMinForTier5: Double = 0.5

        // Interaction
        static let interactionForMessage: Double = 0.3
        static let interactionForConnect: Double = 0.5
        static let interactionForStrongTier: Double = 0.6

        // Potential
        static let potentialForBreakthrough: Double = 0.85
        static let impactForBreakthrough: Double = 0.75

        // Near-miss
        static let nearMissMinEncounters: Int = 2
        static let nearMissMinSeconds: Int = 120
        static let nearMissEscalateEncounters: Int = 3

        // Message recency (seconds)
        static let recentMessageWindow: TimeInterval = 600  // 10 min

        // Potential limits
        static let maxPotentialPerSession: Int = 1
    }

    // MARK: - Session State

    private var potentialSurfacedThisSession: Int = 0

    func resetSession() {
        potentialSurfacedThisSession = 0
    }

    // MARK: - Public API

    /// Evaluates all candidates and returns decisions, sorted by tier priority.
    /// Stops at first matching tier per candidate. Silence is preferred over weak suggestions.
    func evaluate(candidates: [DecisionCandidate], totalAttendees: Int) -> [SurfaceDecision] {
        var decisions: [SurfaceDecision] = []

        for candidate in candidates {
            if let decision = evaluateCandidate(candidate, totalAttendees: totalAttendees) {
                decisions.append(decision)
            }
        }

        // Sort by tier (lower = higher priority), stable within tier
        return decisions.sorted { $0.tier < $1.tier }
    }

    // MARK: - Per-Candidate Decision Tree

    private func evaluateCandidate(_ c: DecisionCandidate, totalAttendees: Int) -> SurfaceDecision? {
        let signals = computeSignals(c, totalAttendees: totalAttendees)

        // ── Global Gate: both users must be minimally active ──
        let bothInactive = !c.viewerIsActive && !c.candidateIsActive
        if bothInactive {
            #if DEBUG
            print("[Decision] SUPPRESS \(c.name): both inactive")
            #endif
            return nil
        }

        // ── Tier 1: Active Conversation ──
        if let d = checkTier1(c, signals: signals) { return d }

        // ── Timing gate for Tier 2+ ──
        let timingGated = signals.timingScore < Gate.timingMinForTier2

        // ── Tier 2: Strong Interaction ──
        if !timingGated, let d = checkTier2(c, signals: signals) { return d }

        // ── Tier 3: Breakthrough Potential ──
        if !timingGated, let d = checkTier3(c, signals: signals, totalAttendees: totalAttendees) { return d }

        // ── Tier 4: Repeated Near-Miss (allowed even with weak timing if strong) ──
        if let d = checkTier4(c, signals: signals) { return d }

        // ── Tier 5: Follow-up Gap ──
        if signals.timingScore >= Gate.timingMinForTier5, let d = checkTier5(c, signals: signals) { return d }

        // ── Tier 6: Silence ──
        #if DEBUG
        print("[Decision] SILENT \(c.name): no tier matched (interaction=\(f2(signals.interactionScore)) timing=\(f2(signals.timingScore)))")
        #endif
        return nil
    }

    // MARK: - Tier Checks

    private func checkTier1(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        guard c.hasRecentMessage,
              let msgAge = c.lastMessageAge,
              msgAge < Gate.recentMessageWindow else { return nil }

        let reason = c.isConnected
            ? "Active conversation — keep it going"
            : "Recent message exchange"

        log(c, tier: .activeConversation, action: .message, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .activeConversation, action: .message,
            reason: reason, signals: signals
        )
    }

    private func checkTier2(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        guard signals.interactionScore >= Gate.interactionForStrongTier else { return nil }

        let action: SurfaceAction
        let reason: String

        if c.isConnected {
            guard signals.interactionScore >= Gate.interactionForMessage else { return nil }
            action = .message
            let mins = c.totalEncounterSeconds / 60
            reason = mins > 5
                ? "Strong interaction — \(mins) min together"
                : "Strong interaction — reach out"
        } else {
            guard signals.interactionScore >= Gate.interactionForConnect else { return nil }
            action = .connect
            let mins = c.totalEncounterSeconds / 60
            reason = mins > 0
                ? "You've been near \(firstName(c.name)) for \(mins) min — connect now"
                : "Strong interaction signal — connect"
        }

        log(c, tier: .strongInteraction, action: action, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .strongInteraction, action: action,
            reason: reason, signals: signals
        )
    }

    private func checkTier3(_ c: DecisionCandidate, signals: DecisionSignals, totalAttendees: Int) -> SurfaceDecision? {
        guard signals.potentialScore >= Gate.potentialForBreakthrough,
              signals.impactScore >= Gate.impactForBreakthrough,
              signals.timingScore >= Gate.timingMinForTier3 else { return nil }

        // Top 5% gate
        let top5pctThreshold = max(1, totalAttendees / 20)
        guard potentialSurfacedThisSession < Gate.maxPotentialPerSession else {
            #if DEBUG
            print("[Decision] Tier3 LIMIT \(c.name): potential cap reached (\(potentialSurfacedThisSession)/\(Gate.maxPotentialPerSession))")
            #endif
            return nil
        }

        potentialSurfacedThisSession += 1

        // Build explainable reason from interests
        let viewerFocus = c.viewerInterests.first ?? "your focus"
        let theirFocus = c.theirInterests.first ?? "their focus"
        let reason = "You focus on \(viewerFocus). \(firstName(c.name)) focuses on \(theirFocus)."

        let action: SurfaceAction = c.isConnected ? .message : .connect

        log(c, tier: .breakthroughPotential, action: action, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .breakthroughPotential, action: action,
            reason: reason, signals: signals
        )
    }

    private func checkTier4(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        guard c.encounterCount >= Gate.nearMissMinEncounters,
              c.totalEncounterSeconds >= Gate.nearMissMinSeconds,
              !c.isConnected else { return nil }

        // Escalation check
        let escalated = c.encounterCount >= Gate.nearMissEscalateEncounters
            || signals.timingScore >= Gate.timingMinForTier2

        let mins = c.totalEncounterSeconds / 60
        let reason = escalated
            ? "You keep crossing paths with \(firstName(c.name)) (\(c.encounterCount)× encounters, \(mins) min) — this could be meaningful"
            : "You've crossed paths with \(firstName(c.name)) \(c.encounterCount) times — connect?"

        log(c, tier: .repeatedNearMiss, action: .connect, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .repeatedNearMiss, action: .connect,
            reason: reason, signals: signals
        )
    }

    private func checkTier5(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        guard c.isConnected, !c.hasRecentMessage else { return nil }

        let reason = "You're connected but haven't messaged — say hello"

        log(c, tier: .followUpGap, action: .message, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .followUpGap, action: .message,
            reason: reason, signals: signals
        )
    }

    // MARK: - Signal Computation (normalized 0–1, for threshold comparison ONLY)

    private func computeSignals(_ c: DecisionCandidate, totalAttendees: Int) -> DecisionSignals {
        // Interaction score: encounter strength + messaging
        let encNorm = min(Double(c.totalEncounterSeconds) / 900.0, 1.0) // 15 min = 1.0
        let msgNorm: Double = c.hasRecentMessage ? 0.4 : 0.0
        let connNorm: Double = c.isConnected ? 0.2 : 0.0
        let interactionScore = min(encNorm + msgNorm + connNorm, 1.0)

        // Potential score: shared interests depth
        let interestOverlap = Double(c.sharedInterests.count)
        let maxPossible = max(Double(min(c.viewerInterests.count, c.theirInterests.count)), 1.0)
        let potentialScore = min(interestOverlap / maxPossible, 1.0)

        // Impact score: complementarity (different interests that could combine)
        let viewerSet = Set(c.viewerInterests)
        let theirSet = Set(c.theirInterests)
        let uniqueToThem = theirSet.subtracting(viewerSet).count
        let impactScore = min(Double(uniqueToThem + c.sharedInterests.count) / max(Double(theirSet.count), 1.0), 1.0)

        // Readiness
        let readinessA: Double = c.viewerIsActive ? 1.0 : 0.3
        let readinessB: Double = c.candidateIsActive ? 1.0 : 0.3

        // Intent: recent interaction signals intent
        var intent: Double = 0.0
        if c.hasRecentMessage { intent += 0.5 }
        if let age = c.lastSeenAge, age < 600 { intent += 0.5 }
        else if let age = c.lastSeenAge, age < 3600 { intent += 0.2 }
        intent = min(intent, 1.0)

        let timingScore = readinessA * readinessB * max(intent, 0.1)

        return DecisionSignals(
            interactionScore: interactionScore,
            potentialScore: potentialScore,
            impactScore: impactScore,
            timingScore: timingScore,
            encounterSeconds: c.totalEncounterSeconds,
            encounterCount: c.encounterCount,
            isConnected: c.isConnected,
            hasRecentMessage: c.hasRecentMessage,
            sharedInterests: c.sharedInterests
        )
    }

    // MARK: - Helpers

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    private func f2(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func log(_ c: DecisionCandidate, tier: DecisionTier, action: SurfaceAction, signals: DecisionSignals) {
        #if DEBUG
        print("[Decision] TIER\(tier.rawValue) \(c.name): action=\(action.rawValue) interaction=\(f2(signals.interactionScore)) potential=\(f2(signals.potentialScore)) impact=\(f2(signals.impactScore)) timing=\(f2(signals.timingScore)) enc=\(signals.encounterSeconds)s×\(signals.encounterCount)")
        #endif
    }
}
