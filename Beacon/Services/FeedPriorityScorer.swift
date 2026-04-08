import Foundation

/// Centralized, deterministic priority scoring for feed items.
/// Computes a single score from item type + source data.
/// All tuning knobs are named constants at the top.
///
/// Score = baseScore + recencyBoost + typeSpecificBoost
///
/// Higher score = higher in feed.
enum FeedPriorityScorer {

    // MARK: - Base Scores (by item type)

    static let messageBase:    Double = 100
    static let connectionBase: Double = 80
    static let suggestionBase: Double = 70
    static let encounterBase:  Double = 60

    // MARK: - Recency Boosts (based on source timestamp age)

    static let recency10Min: Double = 20
    static let recency1Hour: Double = 15
    static let recency6Hour: Double = 10
    static let recency24Hour: Double = 5
    static let recencyOlder:  Double = 0

    // MARK: - Encounter Strength Boosts (based on overlap_seconds)

    static let encounterStrong:   Double = 20  // >= 900s (15 min)
    static let encounterMedium:   Double = 10  // >= 300s (5 min)
    static let encounterLight:    Double = 5   // >= 60s
    static let encounterBrief:    Double = 0   // < 60s

    // MARK: - Connection Freshness Boost

    static let connectionFreshBoost: Double = 10  // created within 24h

    // MARK: - Public API

    /// Score a message feed item.
    /// - Parameter sourceTimestamp: the latest message's created_at
    static func scoreMessage(sourceTimestamp: Date?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let total = messageBase + recency

        #if DEBUG
        let actorLabel = "message"
        print("[FeedScore] type=\(actorLabel) base=\(messageBase) recency=\(recency) total=\(total)")
        #endif

        return total
    }

    /// Score a connection feed item.
    /// - Parameter connectionCreatedAt: the connection's created_at timestamp
    static func scoreConnection(connectionCreatedAt: Date?) -> Double {
        let recency = recencyBoost(for: connectionCreatedAt)
        let freshness = connectionFreshnessBoost(createdAt: connectionCreatedAt)
        let total = connectionBase + recency + freshness

        #if DEBUG
        print("[FeedScore] type=connection base=\(connectionBase) recency=\(recency) freshness=\(freshness) total=\(total)")
        #endif

        return total
    }

    /// Score an encounter feed item.
    /// - Parameters:
    ///   - sourceTimestamp: encounter's last_seen_at or first_seen_at
    ///   - overlapSeconds: BLE proximity overlap duration
    static func scoreEncounter(sourceTimestamp: Date?, overlapSeconds: Int?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let strength = encounterStrengthBoost(overlapSeconds: overlapSeconds ?? 0)
        let total = encounterBase + recency + strength

        #if DEBUG
        print("[FeedScore] type=encounter base=\(encounterBase) recency=\(recency) overlapBoost=\(strength) overlap=\(overlapSeconds ?? 0)s total=\(total)")
        #endif

        return total
    }

    /// Score a suggestion feed item.
    /// - Parameter sourceTimestamp: when the suggestion was generated
    static func scoreSuggestion(sourceTimestamp: Date?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let total = suggestionBase + recency

        #if DEBUG
        print("[FeedScore] type=suggestion base=\(suggestionBase) recency=\(recency) total=\(total)")
        #endif

        return total
    }

    // MARK: - Modifiers (private)

    /// Recency boost based on how recent the source timestamp is.
    private static func recencyBoost(for timestamp: Date?) -> Double {
        guard let ts = timestamp else { return recencyOlder }
        let age = Date().timeIntervalSince(ts)

        if age < 600       { return recency10Min }   // < 10 min
        if age < 3600      { return recency1Hour }   // < 1 hour
        if age < 21600     { return recency6Hour }    // < 6 hours
        if age < 86400     { return recency24Hour }   // < 24 hours
        return recencyOlder
    }

    /// Encounter strength boost based on BLE overlap duration.
    private static func encounterStrengthBoost(overlapSeconds: Int) -> Double {
        if overlapSeconds >= 900 { return encounterStrong }
        if overlapSeconds >= 300 { return encounterMedium }
        if overlapSeconds >= 60  { return encounterLight }
        return encounterBrief
    }

    /// Freshness boost for connections created within 24 hours.
    private static func connectionFreshnessBoost(createdAt: Date?) -> Double {
        guard let ts = createdAt else { return 0 }
        let age = Date().timeIntervalSince(ts)
        return age < 86400 ? connectionFreshBoost : 0
    }
}
