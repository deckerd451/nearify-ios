import Foundation

/// Centralized, deterministic priority scoring for feed items.
/// Uses temporal priority model: Priority = time_decay × signal_strength.
/// Strong interactions decay slower; weak interactions decay faster.
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

    /// Score a message feed item using temporal priority.
    /// - Parameter sourceTimestamp: the latest message's created_at
    static func scoreMessage(sourceTimestamp: Date?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let baseTotal = messageBase + recency

        // Temporal priority: messages have high signal strength
        let age = sourceTimestamp.map { Date().timeIntervalSince($0) }
        let temporalBoost = TemporalResolver.temporalPriority(
            lastSeenAge: age,
            signalStrength: 0.9
        ) * 50  // Scale to match base scoring range

        let total = baseTotal + temporalBoost

        #if DEBUG
        print("[FeedScore] type=message base=\(messageBase) recency=\(recency) temporal=\(String(format: "%.1f", temporalBoost)) total=\(String(format: "%.1f", total))")
        #endif

        return total
    }

    /// Score a connection feed item using temporal priority.
    /// - Parameter connectionCreatedAt: the connection's created_at timestamp
    static func scoreConnection(connectionCreatedAt: Date?) -> Double {
        let recency = recencyBoost(for: connectionCreatedAt)
        let freshness = connectionFreshnessBoost(createdAt: connectionCreatedAt)
        let baseTotal = connectionBase + recency + freshness

        let age = connectionCreatedAt.map { Date().timeIntervalSince($0) }
        let temporalBoost = TemporalResolver.temporalPriority(
            lastSeenAge: age,
            signalStrength: 0.6
        ) * 40

        let total = baseTotal + temporalBoost

        #if DEBUG
        print("[FeedScore] type=connection base=\(connectionBase) recency=\(recency) freshness=\(freshness) temporal=\(String(format: "%.1f", temporalBoost)) total=\(String(format: "%.1f", total))")
        #endif

        return total
    }

    /// Score an encounter feed item using temporal priority.
    /// Strong encounters decay slower than weak ones.
    static func scoreEncounter(sourceTimestamp: Date?, overlapSeconds: Int?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let overlap = overlapSeconds ?? 0
        let strength = encounterStrengthBoost(overlapSeconds: overlap)
        let baseTotal = encounterBase + recency + strength

        // Signal strength adapts to encounter duration
        let signalStrength: Double
        if overlap >= 900      { signalStrength = 1.0 }
        else if overlap >= 300 { signalStrength = 0.7 }
        else if overlap >= 60  { signalStrength = 0.4 }
        else                   { signalStrength = 0.15 }

        let age = sourceTimestamp.map { Date().timeIntervalSince($0) }
        let temporalBoost = TemporalResolver.temporalPriority(
            lastSeenAge: age,
            signalStrength: signalStrength
        ) * 50

        let total = baseTotal + temporalBoost

        #if DEBUG
        print("[FeedScore] type=encounter base=\(encounterBase) recency=\(recency) overlapBoost=\(strength) overlap=\(overlap)s temporal=\(String(format: "%.1f", temporalBoost)) total=\(String(format: "%.1f", total))")
        #endif

        return total
    }

    /// Score a suggestion feed item.
    /// - Parameter sourceTimestamp: when the suggestion was generated
    static func scoreSuggestion(sourceTimestamp: Date?) -> Double {
        let recency = recencyBoost(for: sourceTimestamp)
        let baseTotal = suggestionBase + recency

        let age = sourceTimestamp.map { Date().timeIntervalSince($0) }
        let temporalBoost = TemporalResolver.temporalPriority(
            lastSeenAge: age,
            signalStrength: 0.5
        ) * 30

        let total = baseTotal + temporalBoost

        #if DEBUG
        print("[FeedScore] type=suggestion base=\(suggestionBase) recency=\(recency) temporal=\(String(format: "%.1f", temporalBoost)) total=\(String(format: "%.1f", total))")
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
