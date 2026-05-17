import Foundation
import Combine

// MARK: - ProfileSignalService
//
// Thin aggregator that reads from DynamicProfileService, BehaviorProfileService,
// and RelationshipMemoryService to produce lightweight behavioral signals for
// Arrival Brief personalization.
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

    // MARK: - Alignment Context (for pre-event person reasons)

    /// Returns a context string explaining why the current user and a specific attendee
    /// have alignment, using cross-event signals. Returns nil when no specific context
    /// can be derived — caller falls back to standard reason generation.
    ///
    /// Examples of output:
    ///   "You've crossed paths three times — worth making it official."
    ///   "Consistent overlap in health + AI across events."
    ///   "Aligned on your 'Find a cofounder' goal pattern."
    func alignmentContext(for relationship: RelationshipMemory?) -> String? {
        guard let rel = relationship else { return nil }

        // Repeated co-attendance is the strongest, most factual signal.
        if rel.encounterCount >= 4 {
            return "You've crossed paths \(rel.encounterCount) times — worth making it official."
        }
        if rel.encounterCount == 3 {
            return "You've crossed paths three times. A proper conversation is overdue."
        }

        // Mutual interests that also appear in the user's own broader theme patterns.
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

        // Dominant goal aligns with this person's shared interests.
        if let dominant = dominantGoal {
            let goalTokens = Set(
                dominant.lowercased()
                    .components(separatedBy: .whitespaces)
                    .filter { $0.count > 3 }
            )
            let goalAligned = rel.sharedInterests.contains { interest in
                goalTokens.contains { interest.lowercased().contains($0) }
            }
            if goalAligned {
                return "Aligned with your \"\(dominant)\" goal pattern."
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

        // Complementary domain: their shared interest differs from the user's top theme.
        if let rel = relationship,
           let myTop = topThemes.first {
            let complementary = rel.sharedInterests.first {
                $0.lowercased() != myTop.lowercased() && !$0.isEmpty
            }
            if let comp = complementary {
                return "Ask about their \(comp) work — it complements your \(myTop) background."
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
