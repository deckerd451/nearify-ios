import Foundation

// MARK: - Temporal State

/// Time-aware interaction states. Timing windows adapt based on
/// interaction strength, repeated encounters, and event density.
enum TemporalState: Int, Comparable {
    case immediate = 0   // Very recent proximity, user is nearby now
    case live      = 1   // Recent within current event window
    case active    = 2   // Meaningful interaction during event
    case recent    = 3   // Same day, post-event
    case stale     = 4   // Older

    static func < (lhs: TemporalState, rhs: TemporalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .immediate: return "Immediate"
        case .live:      return "Live"
        case .active:    return "Active"
        case .recent:    return "Recent"
        case .stale:     return "Stale"
        }
    }
}

// MARK: - Temporal Resolver

/// Resolves temporal state with adaptive windows.
/// Strong interactions decay slower; weak interactions decay faster.
enum TemporalResolver {

    /// Resolve temporal state for an interaction.
    /// - Parameters:
    ///   - lastSeenAge: seconds since last seen/interaction
    ///   - signalStrength: normalized 0–1 interaction strength
    ///   - encounterCount: number of distinct encounters
    ///   - eventDensity: normalized 0–1 (higher = busier event)
    static func resolve(
        lastSeenAge: TimeInterval?,
        signalStrength: Double,
        encounterCount: Int = 1,
        eventDensity: Double = 0.5
    ) -> TemporalState {
        guard let age = lastSeenAge else { return .stale }

        // Adaptive multiplier: strong signals stretch windows, weak signals shrink them
        // Repeated encounters also stretch windows (familiarity persists)
        let strengthMultiplier = 0.5 + (signalStrength * 1.0)  // 0.5x to 1.5x
        let repeatMultiplier = min(1.0 + Double(encounterCount - 1) * 0.2, 2.0)  // up to 2x
        let densityMultiplier = 0.8 + (eventDensity * 0.4)  // 0.8x to 1.2x

        let adapt = strengthMultiplier * repeatMultiplier * densityMultiplier

        // Base windows (seconds) — these flex with the multiplier
        let immediateWindow: TimeInterval = 120 * adapt    // ~2 min base
        let liveWindow: TimeInterval      = 900 * adapt    // ~15 min base
        let activeWindow: TimeInterval    = 3600 * adapt   // ~1 hour base
        let recentWindow: TimeInterval    = 86400 * adapt  // ~24 hours base

        if age < immediateWindow { return .immediate }
        if age < liveWindow      { return .live }
        if age < activeWindow    { return .active }
        if age < recentWindow    { return .recent }
        return .stale
    }

    /// Compute priority score: time_decay × signal_strength.
    /// Strong interactions decay slower; weak interactions decay faster.
    static func temporalPriority(
        lastSeenAge: TimeInterval?,
        signalStrength: Double,
        encounterCount: Int = 1
    ) -> Double {
        guard let age = lastSeenAge, age >= 0 else { return 0 }

        // Decay half-life adapts to signal strength
        // Strong signal: half-life ~30 min. Weak signal: half-life ~5 min.
        let baseHalfLife: TimeInterval = 300  // 5 min
        let strengthBonus = signalStrength * 1500  // up to +25 min
        let repeatBonus = Double(max(encounterCount - 1, 0)) * 300  // +5 min per repeat
        let halfLife = baseHalfLife + strengthBonus + repeatBonus

        let decay = pow(0.5, age / halfLife)
        return decay * signalStrength
    }
}
