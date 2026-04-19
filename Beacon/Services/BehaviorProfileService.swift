import Foundation
import Combine

// MARK: - Behavior Tendency

/// A single observed behavioral tendency with confidence.
/// Only surfaced when confidence meets threshold (pattern repeated ≥ 2–3 times).
struct BehaviorTendency: Identifiable {
    let id: String
    let insight: String       // "For You" phrasing
    let recommendation: String // "Best Move" phrasing
    let confidence: Int        // number of supporting observations
    let minConfidence: Int     // threshold to surface

    var isConfident: Bool { confidence >= minConfidence }
}

// MARK: - Behavior Profile Service

/// Analyzes the user's feed history to derive behavioral tendencies.
/// Purely client-side — reads from FeedService.shared.feedItems.
/// No new queries, no backend dependencies.
@MainActor
final class BehaviorProfileService: ObservableObject {

    static let shared = BehaviorProfileService()

    @Published private(set) var tendencies: [BehaviorTendency] = []
    @Published private(set) var lastComputed: Date?

    private init() {}

    // MARK: - Public API

    /// Recomputes behavioral tendencies from current feed data.
    /// Safe to call on Home appear — skips if computed within 5 minutes.
    func refresh() {
        if let last = lastComputed, Date().timeIntervalSince(last) < 300 { return }
        tendencies = computeTendencies()
        lastComputed = Date()

        #if DEBUG
        let confident = tendencies.filter { $0.isConfident }
        print("[Behavior] Computed \(tendencies.count) tendencies, \(confident.count) confident")
        for t in confident {
            print("[Behavior]   \(t.id): \(t.confidence)/\(t.minConfidence) — \(t.insight)")
        }
        #endif
    }

    /// Returns only tendencies that meet their confidence threshold.
    var confidentTendencies: [BehaviorTendency] {
        tendencies.filter { $0.isConfident }
    }

    /// Returns the single best "For You" behavioral insight, if any.
    var bestInsight: String? {
        confidentTendencies.max(by: { $0.confidence < $1.confidence })?.insight
    }

    /// Returns the single best "Best Move" behavioral recommendation, if any.
    var bestRecommendation: String? {
        confidentTendencies.max(by: { $0.confidence < $1.confidence })?.recommendation
    }

    // MARK: - Tendency Computation

    private func computeTendencies() -> [BehaviorTendency] {
        let feedItems = FeedService.shared.feedItems
        guard !feedItems.isEmpty else { return [] }

        let encounters = feedItems.filter { $0.feedType == .encounter }
        let connections = feedItems.filter { $0.feedType == .connection }
        let messages = feedItems.filter { $0.feedType == .message }

        let encounterActorIds = Set(encounters.compactMap { $0.actorProfileId })
        let connectionActorIds = Set(connections.compactMap { $0.actorProfileId })
        let messageActorIds = Set(messages.compactMap { $0.actorProfileId })

        var result: [BehaviorTendency] = []

        // ── 1. Repeat Encounter Tendency ──
        // Does this user encounter the same people multiple times?
        var encounterCounts: [UUID: Int] = [:]
        for item in encounters {
            if let actorId = item.actorProfileId {
                encounterCounts[actorId, default: 0] += 1
            }
        }
        let repeatEncounterPeople = encounterCounts.values.filter { $0 >= 2 }.count

        result.append(BehaviorTendency(
            id: "repeat-encounters",
            insight: "You usually connect after seeing someone more than once.",
            recommendation: "Let encounters repeat before committing to a conversation.",
            confidence: repeatEncounterPeople,
            minConfidence: 2
        ))

        // ── 2. Familiar-First Tendency ──
        // Does this user message/connect with people they've encountered before?
        let messagedAfterEncounter = messageActorIds.intersection(encounterActorIds).count
        let connectedAfterEncounter = connectionActorIds.intersection(encounterActorIds).count
        let familiarConversions = messagedAfterEncounter + connectedAfterEncounter

        result.append(BehaviorTendency(
            id: "familiar-first",
            insight: "You tend to engage with people you've already encountered.",
            recommendation: "Start with people you've already crossed paths with.",
            confidence: familiarConversions,
            minConfidence: 3
        ))

        // ── 3. Follow-Through Tendency ──
        // Does this user message people after connecting?
        let messagedAfterConnection = messageActorIds.intersection(connectionActorIds).count

        result.append(BehaviorTendency(
            id: "follow-through",
            insight: "You follow up after making connections — that's a strong pattern.",
            recommendation: "Your follow-through works. Plan who to message before leaving.",
            confidence: messagedAfterConnection,
            minConfidence: 2
        ))

        // ── 4. Explorer Tendency ──
        // Does this user encounter many different people (breadth over depth)?
        let uniqueEncounterPeople = encounterActorIds.count
        let deepEncounters = encounterCounts.values.filter { $0 >= 3 }.count
        let isExplorer = uniqueEncounterPeople >= 5 && deepEncounters <= 1

        result.append(BehaviorTendency(
            id: "explorer",
            insight: "You tend to explore widely before settling into conversations.",
            recommendation: "Move through the room before committing. Your best connections come from breadth.",
            confidence: isExplorer ? uniqueEncounterPeople : 0,
            minConfidence: 5
        ))

        // ── 5. Depth Tendency ──
        // Does this user spend extended time with fewer people?
        let longEncounters = encounters.filter {
            ($0.metadata?.overlapSeconds ?? 0) >= 300
        }.count

        result.append(BehaviorTendency(
            id: "depth-seeker",
            insight: "Your strongest connections come from extended time with fewer people.",
            recommendation: "Find one strong signal and stay with it. Depth works for you.",
            confidence: longEncounters,
            minConfidence: 2
        ))

        // ── 6. Late Engager Tendency ──
        // Does this user's activity cluster later in events?
        // Proxy: are most connections/messages created >30min after first encounter?
        let encounterDates = encounters.compactMap { $0.createdAt }.sorted()
        let connectionDates = connections.compactMap { $0.createdAt }.sorted()
        if let firstEncounter = encounterDates.first {
            let lateConnections = connectionDates.filter {
                $0.timeIntervalSince(firstEncounter) > 1800 // >30min after first encounter
            }.count
            let earlyConnections = connectionDates.filter {
                $0.timeIntervalSince(firstEncounter) <= 1800
            }.count

            result.append(BehaviorTendency(
                id: "late-engager",
                insight: "Your strongest interactions tend to happen later in events.",
                recommendation: "Don't rush early. Your pattern shows value builds over time here.",
                confidence: lateConnections >= 2 && lateConnections > earlyConnections ? lateConnections : 0,
                minConfidence: 2
            ))
        }

        return result
    }
}
