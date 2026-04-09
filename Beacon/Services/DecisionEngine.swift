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
    case fallback           = 6  // NEW: guaranteed output for meaningful candidates

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
        case .fallback:              return "Nearby"
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
///
/// CRITICAL RULE: The engine must NOT return zero decisions when meaningful
/// signal exists. A fallback tier guarantees at least one output.
@MainActor
final class DecisionEngine {

    static let shared = DecisionEngine()
    private init() {}

    // MARK: - Tunable Thresholds
    //
    // CHANGELOG:
    //   v2 — Lowered timing gates, interaction thresholds, near-miss minimums.
    //         Added fallback tier. Widened candidateIsActive window.
    //         Root cause: timing formula required both recent message AND recent
    //         proximity, which almost never co-occurred. Interaction threshold
    //         required 9+ min encounters. encounterCount was structurally capped
    //         at 1 due to DB unique constraint. No fallback existed.

    private enum Gate {
        // ── Timing ──
        // v1: 0.6 / 0.7 / 0.5 — too strict, required message+proximity
        // v2: lowered to let encounter-only candidates through
        static let timingMinForTier2: Double = 0.25   // was 0.6
        static let timingMinForTier3: Double = 0.3    // was 0.7
        static let timingMinForTier5: Double = 0.15   // was 0.5

        // ── Interaction ──
        // v1: 0.3 / 0.5 / 0.6 — required 540s+ encounters for strong tier
        // v2: lowered so 60s encounter + connection can qualify
        static let interactionForMessage: Double = 0.15    // was 0.3
        static let interactionForConnect: Double = 0.15    // was 0.5
        static let interactionForStrongTier: Double = 0.25 // was 0.6

        // ── Potential ──
        // v1: 0.85 / 0.75 — required near-perfect interest overlap
        // v2: lowered to surface interest-based matches more often
        static let potentialForBreakthrough: Double = 0.5  // was 0.85
        static let impactForBreakthrough: Double = 0.4     // was 0.75

        // ── Near-miss ──
        // v1: 2 encounters / 120s — but encounterCount was always 0 or 1
        // v2: allow 1 encounter with sufficient duration
        static let nearMissMinEncounters: Int = 1      // was 2
        static let nearMissMinSeconds: Int = 60        // was 120
        static let nearMissEscalateEncounters: Int = 2 // was 3

        // ── Message recency ──
        static let recentMessageWindow: TimeInterval = 600  // 10 min (unchanged)

        // ── Session caps ──
        static let maxPotentialPerSession: Int = 1
        static let maxFallbackPerSession: Int = 2

        // ── Fallback: minimum signal to be considered meaningful ──
        // A candidate qualifies for fallback if ANY of these are true:
        //   - encounter >= 30 seconds
        //   - isConnected
        //   - lastSeenAge < 300 seconds (seen in last 5 min)
        static let fallbackMinEncounterSeconds: Int = 30
        static let fallbackRecentSeenWindow: TimeInterval = 300
    }

    // MARK: - Session State

    private var potentialSurfacedThisSession: Int = 0
    private var fallbackSurfacedThisSession: Int = 0

    func resetSession() {
        potentialSurfacedThisSession = 0
        fallbackSurfacedThisSession = 0
    }

    // MARK: - Public API

    /// Evaluates all candidates and returns decisions, sorted by tier priority.
    /// GUARANTEE: If at least one candidate has meaningful signal, at least one
    /// decision will be returned (via fallback tier if no primary tier matches).
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
        // Relaxed: only suppress if BOTH are inactive. A single active user
        // is enough — the other may just have a stale heartbeat.
        let bothInactive = !c.viewerIsActive && !c.candidateIsActive
        if bothInactive {
            #if DEBUG
            print("[Decision] SUPPRESS \(c.name): both inactive")
            #endif
            return nil
        }

        // ── Tier 1: Active Conversation ──
        if let d = checkTier1(c, signals: signals) { return d }

        // ── Tier 2: Strong Interaction ──
        if signals.timingScore >= Gate.timingMinForTier2,
           let d = checkTier2(c, signals: signals) { return d }

        // ── Tier 3: Breakthrough Potential ──
        if signals.timingScore >= Gate.timingMinForTier3,
           let d = checkTier3(c, signals: signals, totalAttendees: totalAttendees) { return d }

        // ── Tier 4: Repeated Near-Miss ──
        if let d = checkTier4(c, signals: signals) { return d }

        // ── Tier 5: Follow-up Gap ──
        if signals.timingScore >= Gate.timingMinForTier5,
           let d = checkTier5(c, signals: signals) { return d }

        // ── Tier 6: Fallback (MANDATORY — prevents silence) ──
        if let d = checkFallback(c, signals: signals) { return d }

        // ── True silence: candidate has no meaningful signal at all ──
        #if DEBUG
        print("[Decision] SILENT \(c.name): no signal (enc=\(c.totalEncounterSeconds)s conn=\(c.isConnected) lastSeen=\(c.lastSeenAge.map { "\(Int($0))s" } ?? "nil"))")
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
        let mins = c.totalEncounterSeconds / 60

        if c.isConnected {
            guard signals.interactionScore >= Gate.interactionForMessage else { return nil }
            action = .message
            reason = mins > 0
                ? "You spent \(mins) min near \(firstName(c.name)) — say hello"
                : "Strong interaction — reach out"
        } else {
            guard signals.interactionScore >= Gate.interactionForConnect else { return nil }
            action = .connect
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
              signals.impactScore >= Gate.impactForBreakthrough else { return nil }

        guard potentialSurfacedThisSession < Gate.maxPotentialPerSession else {
            #if DEBUG
            print("[Decision] Tier3 LIMIT \(c.name): potential cap reached")
            #endif
            return nil
        }

        potentialSurfacedThisSession += 1

        let shared = c.sharedInterests.prefix(2).joined(separator: " & ")
        let reason: String
        if !shared.isEmpty {
            reason = "You and \(firstName(c.name)) share \(shared)"
        } else {
            let viewerFocus = c.viewerInterests.first ?? "your focus"
            let theirFocus = c.theirInterests.first ?? "their focus"
            reason = "You focus on \(viewerFocus). \(firstName(c.name)) focuses on \(theirFocus)."
        }

        let action: SurfaceAction = c.isConnected ? .message : .connect

        log(c, tier: .breakthroughPotential, action: action, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .breakthroughPotential, action: action,
            reason: reason, signals: signals
        )
    }

    private func checkTier4(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        // Near-miss: meaningful encounter but not connected
        guard !c.isConnected,
              c.encounterCount >= Gate.nearMissMinEncounters,
              c.totalEncounterSeconds >= Gate.nearMissMinSeconds else { return nil }

        let mins = c.totalEncounterSeconds / 60
        let reason: String
        if c.encounterCount >= Gate.nearMissEscalateEncounters {
            reason = "You keep crossing paths with \(firstName(c.name)) (\(c.encounterCount)× encounters, \(mins) min) — this could be meaningful"
        } else if mins > 0 {
            reason = "You crossed paths with \(firstName(c.name)) for \(mins) min — connect?"
        } else {
            reason = "You crossed paths with \(firstName(c.name)) — connect?"
        }

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

    // MARK: - Fallback Tier (MANDATORY — prevents silence)

    /// Emits a lower-confidence decision for any candidate with meaningful signal.
    /// This is the safety net: if no primary tier matched but the candidate is
    /// real (encounter, connection, or recent proximity), we still surface them.
    private func checkFallback(_ c: DecisionCandidate, signals: DecisionSignals) -> SurfaceDecision? {
        guard fallbackSurfacedThisSession < Gate.maxFallbackPerSession else {
            #if DEBUG
            print("[Decision] Fallback LIMIT \(c.name): cap reached (\(fallbackSurfacedThisSession)/\(Gate.maxFallbackPerSession))")
            #endif
            return nil
        }

        // Minimum signal check: candidate must have at least one meaningful indicator
        let hasEncounter = c.totalEncounterSeconds >= Gate.fallbackMinEncounterSeconds
        let isConnected = c.isConnected
        let recentlySeen = c.lastSeenAge.map { $0 < Gate.fallbackRecentSeenWindow } ?? false
        let hasSharedInterests = !c.sharedInterests.isEmpty

        guard hasEncounter || isConnected || recentlySeen || hasSharedInterests else {
            return nil
        }

        fallbackSurfacedThisSession += 1

        let action: SurfaceAction = isConnected ? .message : .viewProfile
        let reason: String
        let mins = c.totalEncounterSeconds / 60

        if hasEncounter && mins > 0 {
            reason = "You spent \(mins) min near \(firstName(c.name)) at this event"
        } else if hasEncounter {
            reason = "You crossed paths with \(firstName(c.name)) at this event"
        } else if isConnected {
            reason = "\(firstName(c.name)) is here — reconnect"
        } else if hasSharedInterests {
            let shared = c.sharedInterests.prefix(2).joined(separator: " & ")
            reason = "You and \(firstName(c.name)) share \(shared)"
        } else {
            reason = "\(firstName(c.name)) is nearby — view profile"
        }

        log(c, tier: .fallback, action: action, signals: signals)
        return SurfaceDecision(
            profileId: c.profileId, name: c.name,
            tier: .fallback, action: action,
            reason: reason, signals: signals
        )
    }

    // MARK: - Signal Computation (normalized 0–1, for threshold comparison ONLY)

    private func computeSignals(_ c: DecisionCandidate, totalAttendees: Int) -> DecisionSignals {
        // ── Interaction score ──
        // v1: 15 min = 1.0 — too strict for real events
        // v2: 5 min = 1.0 — most meaningful encounters are 1-5 min
        let encNorm = min(Double(c.totalEncounterSeconds) / 300.0, 1.0)  // was /900
        let msgNorm: Double = c.hasRecentMessage ? 0.4 : 0.0
        let connNorm: Double = c.isConnected ? 0.2 : 0.0
        let interactionScore = min(encNorm + msgNorm + connNorm, 1.0)

        // ── Potential score: shared interests depth ──
        let interestOverlap = Double(c.sharedInterests.count)
        let maxPossible = max(Double(min(c.viewerInterests.count, c.theirInterests.count)), 1.0)
        let potentialScore = min(interestOverlap / maxPossible, 1.0)

        // ── Impact score: complementarity ──
        let viewerSet = Set(c.viewerInterests)
        let theirSet = Set(c.theirInterests)
        let uniqueToThem = theirSet.subtracting(viewerSet).count
        let impactScore = min(Double(uniqueToThem + c.sharedInterests.count) / max(Double(theirSet.count), 1.0), 1.0)

        // ── Timing score ──
        // v1: readinessA * readinessB * max(intent, 0.1) — required message+proximity
        // v2: readiness is a floor (0.5 if inactive, not 0.3), and intent is more
        //     generous: recent proximity alone gives 0.5, which is enough for Tier 2.
        let readinessA: Double = c.viewerIsActive ? 1.0 : 0.5   // was 0.3
        let readinessB: Double = c.candidateIsActive ? 1.0 : 0.5 // was 0.3

        var intent: Double = 0.0
        if c.hasRecentMessage { intent += 0.5 }
        if let age = c.lastSeenAge, age < 300 { intent += 0.5 }      // was 600
        else if let age = c.lastSeenAge, age < 1800 { intent += 0.3 } // was 3600/0.2
        else if let age = c.lastSeenAge, age < 7200 { intent += 0.1 }
        intent = min(intent, 1.0)

        // Floor: if there's any encounter data at all, timing never goes below 0.15
        let encFloor: Double = c.totalEncounterSeconds > 0 ? 0.15 : 0.0
        let timingScore = max(readinessA * readinessB * max(intent, 0.1), encFloor)

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
