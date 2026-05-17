import Foundation
import Combine

// MARK: - ProfileTendency
//
// Lightweight confidence-weighted signal derived from the user's history.
// INTERNAL ONLY — never exposed publicly or used for ranking.
//
// Sources ranked by trust:
//   .explicitGoal    — user chose this goal (highest trust)
//   .sharedPattern   — interest appears across ≥1 relationships
//   .themePattern    — DynamicProfileService computed theme
//   .behaviorPattern — BehaviorProfileService confident tendency

struct ProfileTendency {
    enum Source {
        case explicitGoal, sharedPattern, themePattern, behaviorPattern
    }
    let category: String    // lowercase key for matching
    let label: String       // human-readable: "Find a cofounder", "Healthcare"
    let confidence: Double  // 0.0–1.0
    let source: Source
    let evidenceCount: Int
}

// MARK: - ProfileSignalService
//
// Aggregates lightweight longitudinal signals from DynamicProfileService,
// BehaviorProfileService, RelationshipMemoryService, and explicit goal history
// to improve Arrival Brief personalization.
//
// PRIVACY RULES (strictly enforced):
//   - All inferred signals are private and local-first.
//   - Goal history (the only persisted data) is a simple [String: Int] count.
//   - Nothing here is ever auto-published to the public profile.
//   - No personality inference, no hidden scores, no opaque rankings.

@MainActor
final class ProfileSignalService {

    static let shared = ProfileSignalService()

    // MARK: - Goal History (persisted to UserDefaults)

    private let goalHistoryKey = "nearify.profileSignals.goalHistory"

    /// How many times the user has selected each intentPrimary value across events.
    /// Derived from explicit user choices — never inferred.
    private(set) var goalHistory: [String: Int] = [:]

    /// The goal the user has selected most often. nil until ≥1 goal is recorded.
    var dominantGoal: String? {
        goalHistory.max(by: { $0.value < $1.value })?.key
    }

    private init() {
        loadGoalHistory()
    }

    // MARK: - Goal Recording

    /// Records an explicit goal selection. Called by EventContextService when
    /// the user sets intentPrimary. Persists across sessions.
    func recordGoal(_ goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        goalHistory[trimmed, default: 0] += 1
        saveGoalHistory()
        #if DEBUG
        print("[ProfileSignals] goal recorded: \"\(trimmed)\" total=\(goalHistory[trimmed] ?? 0)")
        #endif
    }

    // MARK: - Signal Accessors (delegate to existing services — no new computation)

    /// User's top behavioral themes from DynamicProfileService.
    /// Derived from event names, profile interests, and encounter shared interests.
    var topThemes: [String] {
        DynamicProfileService.shared.currentSignals.topThemes
    }

    /// Recent shared interests from encounter and connection history.
    var recentSharedInterests: Set<String> {
        DynamicProfileService.shared.currentSignals.recentSharedInterests
    }

    /// Whether the user has demonstrated follow-up behavior (messages after events).
    var hasFollowUpMomentum: Bool {
        DynamicProfileService.shared.currentSignals.hasFollowUpMomentum
    }

    /// Most confident behavioral tendency, if threshold is met.
    var dominantTendency: BehaviorTendency? {
        BehaviorProfileService.shared.confidentTendencies
            .max(by: { $0.confidence < $1.confidence })
    }

    // MARK: - Profile Tendencies (synthesized from all available sources)

    /// Confidence-weighted tendencies synthesized from goal history, relationship patterns,
    /// and theme signals. Computes from in-memory sources — fast enough to call inline.
    /// Useful even for first-event users (goalHistory alone drives initial tendencies).
    var topTendencies: [ProfileTendency] {
        computeTendencies()
    }

    /// The label of the strongest non-behavioral tendency. Useful for "why this person" copy.
    var dominantTendencyLabel: String? {
        topTendencies.first { $0.source != .behaviorPattern }?.label
    }

    private func computeTendencies() -> [ProfileTendency] {
        var candidates: [ProfileTendency] = []

        // 1. Explicit goal history — highest trust. Even one selection is meaningful.
        for (goal, count) in goalHistory where !goal.isEmpty {
            let raw = min(Double(count) / 4.0, 1.0)
            candidates.append(ProfileTendency(
                category: goal.lowercased(),
                label: goal,
                confidence: max(raw, 0.25),
                source: .explicitGoal,
                evidenceCount: count
            ))
        }

        // 2. Interests repeated across relationships — implicit but reliable.
        var interestFreq: [String: Int] = [:]
        for rel in RelationshipMemoryService.shared.relationships {
            for interest in rel.sharedInterests {
                interestFreq[interest.lowercased(), default: 0] += 1
            }
        }
        for (interest, count) in interestFreq where !interest.isEmpty {
            let confidence = count >= 2 ? min(Double(count) / 5.0, 0.85) : 0.3
            candidates.append(ProfileTendency(
                category: interest,
                label: interest.split(separator: " ").map { $0.capitalized }.joined(separator: " "),
                confidence: confidence,
                source: .sharedPattern,
                evidenceCount: count
            ))
        }

        // 3. DynamicProfileService themes — event name + profile data inference.
        for (index, theme) in DynamicProfileService.shared.currentSignals.topThemes.prefix(3).enumerated() {
            candidates.append(ProfileTendency(
                category: theme.lowercased(),
                label: theme,
                confidence: max(0.6 - Double(index) * 0.1, 0.4),
                source: .themePattern,
                evidenceCount: 1
            ))
        }

        // 4. BehaviorProfileService confident tendencies.
        for tendency in BehaviorProfileService.shared.confidentTendencies {
            candidates.append(ProfileTendency(
                category: tendency.id,
                label: tendency.insight,
                confidence: min(Double(tendency.confidence) / 5.0, 0.8),
                source: .behaviorPattern,
                evidenceCount: tendency.confidence
            ))
        }

        // Deduplicate: for overlapping-token categories, keep highest confidence entry.
        var merged: [ProfileTendency] = []
        outer: for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            for existing in merged where tendencyTokensOverlap(candidate.category, existing.category) {
                continue outer
            }
            merged.append(candidate)
        }

        #if DEBUG
        if !merged.isEmpty {
            print("[ProfileSignals] tendencies: \(merged.prefix(3).map { "\($0.label) (\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", "))")
        }
        #endif

        return merged
    }

    // MARK: - Alignment Context (for pre-event person reasons)

    /// Returns a context string explaining why the current user and a specific attendee
    /// have alignment, using cross-event signals. Returns nil when no specific context
    /// can be derived — caller falls back to standard reason generation.
    ///
    /// Examples of output:
    ///   "You've crossed paths three times. A proper conversation is overdue."
    ///   "You both repeatedly show up around AI + healthcare."
    ///   "Their background aligns with your 'Find a cofounder' focus."
    func alignmentContext(for relationship: RelationshipMemory?) -> String? {
        guard let rel = relationship else { return nil }

        // Repeated co-attendance is the strongest, most factual signal.
        if rel.encounterCount >= 4 {
            return "You've crossed paths \(rel.encounterCount) times — worth making it official."
        }
        if rel.encounterCount == 3 {
            return "You've crossed paths three times. A proper conversation is overdue."
        }

        // Cross-event tendency alignment: user's accumulated patterns match this person.
        let relInterests = rel.sharedInterests
        if !relInterests.isEmpty {
            let matched = topTendencies.filter { tendency in
                relInterests.contains { tendencyTokensOverlap(tendency.category, $0) }
            }
            if matched.count >= 2 {
                let labels = matched.prefix(2).map { $0.label }.joined(separator: " + ")
                return "You both repeatedly show up around \(labels)."
            }
            if let top = matched.first {
                if rel.encounterCount >= 2 {
                    return "You keep crossing paths — both focused on \(top.label)."
                }
                if top.source == .explicitGoal {
                    return "Their background aligns with your \"\(top.label)\" focus."
                }
                if let eventRef = rel.eventContexts.first {
                    return "Consistent \(top.label) overlap — you've both shown up at events like \(eventRef)."
                }
                return "Consistent \(top.label) overlap across events."
            }
        }

        // Mutual reinforcement: themes or recent interests appear in both sides.
        let myThemes = Set(topThemes.map { $0.lowercased() })
        let myRecentInterests = recentSharedInterests
        let mutualReinforced = rel.sharedInterests.filter { interest in
            let tag = interest.lowercased()
            return myThemes.contains(tag) || myRecentInterests.contains(tag)
        }
        if mutualReinforced.count >= 2 {
            let labels = mutualReinforced.prefix(2).joined(separator: " + ")
            return "You both keep showing up around \(labels)."
        }
        if let first = mutualReinforced.first {
            return "Consistent \(first) focus from both sides."
        }

        // Dominant goal overlaps with this person's shared interests.
        if let dominant = dominantGoal {
            let goalAligned = rel.sharedInterests.contains { tendencyTokensOverlap($0, dominant) }
            if goalAligned {
                return "Their background aligns with your \"\(dominant)\" goal."
            }
        }

        return nil
    }

    // MARK: - Mutual Value Framing

    /// Returns a complementary framing line: what this person brings given the user's focus.
    /// Returns nil when insufficient context exists.
    func mutualValueReason(for relationship: RelationshipMemory?) -> String? {
        guard let rel = relationship, !rel.sharedInterests.isEmpty else { return nil }

        // Complementary domain: their focus differs from the user's dominant theme.
        if let myTop = topThemes.first {
            if let theirFocus = rel.sharedInterests.first(where: {
                !tendencyTokensOverlap($0, myTop) && $0.count > 1
            }) {
                return "They bring \(theirFocus) experience — complements your \(myTop) background."
            }
        }

        // Goal-aware framing: they have context relevant to what the user is seeking.
        let goal = dominantGoal ?? EventContextService.shared.cachedContext?.intentPrimary
        if let g = goal, let interest = rel.sharedInterests.first {
            let lower = g.lowercased()
            if lower.contains("cofounder") || lower.contains("co-founder") {
                return "They bring \(interest) background — relevant to your cofounder search."
            }
            if lower.contains("invest") || lower.contains("fund") {
                return "They're active in \(interest) — worth exploring from an investment angle."
            }
            if lower.contains("hire") || lower.contains("team") {
                return "Their \(interest) experience may match what you're hiring for."
            }
        }

        return nil
    }

    // MARK: - Conversation Starters

    /// Generates a personalized conversation starter for a specific attendee pairing.
    /// Returns nil when no specific context is available — caller uses a generic line.
    ///
    /// Priority:
    ///   1. Prior shared event (factual, natural)
    ///   2. Complementary domain framing
    ///   3. Goal-pattern-based opener
    func conversationStarter(for relationship: RelationshipMemory?) -> String? {
        // Prior event context — most specific, most natural.
        if let rel = relationship, rel.encounterCount >= 2,
           let eventContext = rel.eventContexts.first {
            return "You were both at \(eventContext) — good starting point."
        }

        // Complementary domain: their shared interest differs from the user's top tendency.
        if let rel = relationship {
            let myTopLabel = dominantTendencyLabel ?? topThemes.first
            if let myTop = myTopLabel {
                let complementary = rel.sharedInterests.first {
                    !tendencyTokensOverlap($0, myTop) && !$0.isEmpty
                }
                if let comp = complementary {
                    return "Ask about their \(comp) work — it complements your \(myTop) background."
                }
            }
        }

        // Goal-pattern starter: uses dominant goal (repeated) over single-event goal.
        let goal = dominantGoal ?? EventContextService.shared.cachedContext?.intentPrimary
        if let g = goal, !g.isEmpty {
            return goalBasedStarter(g)
        }

        return nil
    }

    private func goalBasedStarter(_ goal: String) -> String? {
        let lower = goal.lowercased()
        if lower.contains("cofounder") || lower.contains("co-founder") {
            return "Ask what they're building and what role they still need."
        }
        if lower.contains("hire") || lower.contains("recruit") || lower.contains("team") {
            return "Ask what kind of problems they get most excited to work on."
        }
        if lower.contains("invest") || lower.contains("fund") || lower.contains("capital") {
            return "Ask what milestone they're driving toward right now."
        }
        if lower.contains("explore") || lower.contains("learn") || lower.contains("research") {
            return "Ask what's surprising them about this space lately."
        }
        if lower.contains("collab") || lower.contains("partner") || lower.contains("build") {
            return "Ask what a good collaboration looks like for them right now."
        }
        if lower.contains("meet") || lower.contains("network") || lower.contains("connect") {
            return "Ask what brought them to this specific event."
        }
        return nil
    }

    // MARK: - Energy-Aware Recommendation Tuning

    /// Recommended number of people to surface based on the user's energy level.
    /// Uses EventContext.energyLevel (assumed 1–10 scale). Defaults to 2.
    var recommendedPersonCount: Int {
        let energy = EventContextService.shared.cachedContext?.energyLevel ?? 5
        switch energy {
        case 1...3: return 1   // Low energy: one highly confident suggestion
        case 4...6: return 2   // Moderate: two suggestions
        default:    return 3   // High energy: full set
        }
    }

    /// Tone modifier for recommendation copy, derived from energy level.
    enum EnergyTone { case soft, neutral, proactive }

    var energyTone: EnergyTone {
        let energy = EventContextService.shared.cachedContext?.energyLevel ?? 5
        switch energy {
        case 1...3: return .soft       // "When you're ready…"
        case 7...10: return .proactive // "Start with Alex — strong alignment."
        default:    return .neutral
        }
    }

    // MARK: - Signal Freshness

    /// Ensures DynamicProfileService and BehaviorProfileService signals are fresh.
    /// Safe to call before building a brief — both have internal rate-limiting.
    func refreshIfNeeded() {
        DynamicProfileService.shared.refresh()
        BehaviorProfileService.shared.refresh()
    }

    // MARK: - Token Helpers (shared with tendency matching)

    private func tendencyTokensOverlap(_ a: String, _ b: String) -> Bool {
        let tokA = tendencyTokens(a)
        let tokB = tendencyTokens(b)
        return !tokA.isDisjoint(with: tokB)
    }

    private func tendencyTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )
    }

    // MARK: - Persistence

    private func loadGoalHistory() {
        guard let data = UserDefaults.standard.data(forKey: goalHistoryKey),
              let stored = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        goalHistory = stored
        #if DEBUG
        print("[ProfileSignals] loaded goal history: \(stored.count) entries")
        #endif
    }

    private func saveGoalHistory() {
        guard let data = try? JSONEncoder().encode(goalHistory) else { return }
        UserDefaults.standard.set(data, forKey: goalHistoryKey)
    }
}
