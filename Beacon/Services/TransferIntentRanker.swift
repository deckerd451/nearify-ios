import Foundation

/// Ranks locally captured encounters into goodbye candidates.
///
/// Produces a sorted list of `TransferIntent` from `LocalEncounterStore` data.
/// Each intent carries a priority level and eligibility flag for future release flows.
///
/// This ranker:
/// - Reads only from LocalEncounterStore (no network dependency)
/// - Does NOT create interaction_events or connection edges
/// - Does NOT modify feed ranking or People/Home logic
/// - Does NOT change any visible app behavior unless explicitly consumed
/// - Logs ranking decisions for debuggability
@MainActor
enum TransferIntentRanker {

    // MARK: - Model

    struct TransferIntent: Identifiable {
        let encounterId: UUID
        let peerPrefix: String
        let resolvedProfileId: UUID?
        let resolvedName: String?
        let resolvedAvatarUrl: String?
        let priorityLevel: PriorityLevel
        let eligibleForRelease: Bool
        let score: Double
        let reasoning: String

        var id: UUID { encounterId }

        enum PriorityLevel: String, Comparable {
            case strong
            case medium
            case weak

            // Comparable conformance for sorting
            private var sortOrder: Int {
                switch self {
                case .strong: return 0
                case .medium: return 1
                case .weak:   return 2
                }
            }

            static func < (lhs: PriorityLevel, rhs: PriorityLevel) -> Bool {
                lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    // MARK: - Thresholds

    private enum Threshold {
        // Strong: sustained proximity with good signal
        static let strongDuration: Int = 120        // 2+ minutes
        static let strongConfidence: Double = 0.6
        static let strongAvgRSSI: Double = -70.0

        // Medium: meaningful but shorter interaction
        static let mediumDuration: Int = 30          // 30+ seconds
        static let mediumConfidence: Double = 0.3
        static let mediumAvgRSSI: Double = -80.0

        // Minimum to be considered at all
        static let minimumDuration: Int = 10         // 10 seconds
        static let minimumSamples: Int = 2           // At least 2 BLE readings

        // Caps
        static let maxStrongCandidates: Int = 3
        static let maxTotalCandidates: Int = 10

        // Rolling window — only consider recent encounters
        static let rollingWindow: TimeInterval = 4 * 3600  // 4 hours
    }

    // MARK: - Ranking

    /// Ranks all locally captured encounters and returns sorted TransferIntents.
    /// Optionally scoped to a specific event.
    static func rank(forEvent eventId: UUID? = nil) -> [TransferIntent] {
        let store = LocalEncounterStore.shared
        let allEncounters: [LocalEncounterStore.CapturedEncounter]

        if let eventId {
            allEncounters = store.encounters(forEvent: eventId)
        } else {
            allEncounters = store.allEncounters
        }

        // Apply rolling window
        let cutoff = Date().addingTimeInterval(-Threshold.rollingWindow)
        let recent = allEncounters.filter { $0.lastSeenAt > cutoff }

        #if DEBUG
        print("[TransferRank] ── ranking \(recent.count) encounters (window: \(Int(Threshold.rollingWindow / 3600))h) ──")
        #endif

        var intents: [TransferIntent] = []

        for encounter in recent {
            let result = classify(encounter)

            guard let result else {
                #if DEBUG
                print("[TransferRank]   excluded: prefix=\(encounter.peerEphemeralId) — \(excludeReason(encounter))")
                #endif
                continue
            }

            intents.append(result)
        }

        // Sort: strong first, then by score descending within each level
        intents.sort { a, b in
            if a.priorityLevel != b.priorityLevel {
                return a.priorityLevel < b.priorityLevel
            }
            return a.score > b.score
        }

        // Cap strong candidates
        var strongCount = 0
        intents = intents.filter { intent in
            if intent.priorityLevel == .strong {
                strongCount += 1
                return strongCount <= Threshold.maxStrongCandidates
            }
            return true
        }

        // Cap total
        let capped = Array(intents.prefix(Threshold.maxTotalCandidates))

        #if DEBUG
        print("[TransferRank] ── final candidates ──")
        for intent in capped {
            let name = intent.resolvedName ?? intent.peerPrefix
            print("[TransferRank]   \(intent.priorityLevel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) | \(name) | score=\(String(format: "%.2f", intent.score)) | release=\(intent.eligibleForRelease) | \(intent.reasoning)")
        }
        if capped.isEmpty {
            print("[TransferRank]   (none)")
        }
        print("[TransferRank] ── done ──")
        #endif

        return capped
    }

    // MARK: - Classification

    private static func classify(_ encounter: LocalEncounterStore.CapturedEncounter) -> TransferIntent? {
        let duration = encounter.duration
        let confidence = encounter.confidenceScore
        let avgRSSI = encounter.signalStrengthSummary.averageRSSI
        let samples = encounter.signalStrengthSummary.sampleCount

        // Gate: minimum thresholds
        guard duration >= Threshold.minimumDuration else { return nil }
        guard samples >= Threshold.minimumSamples else { return nil }

        // Compute composite score (0–100 scale for readability)
        let durationScore = min(Double(duration) / 300.0, 1.0) * 40.0     // max 40 pts
        let signalScore = signalQuality(avgRSSI) * 25.0                    // max 25 pts
        let confidenceBonus = confidence * 20.0                             // max 20 pts
        let consistencyBonus = signalConsistency(encounter) * 15.0         // max 15 pts
        let totalScore = durationScore + signalScore + confidenceBonus + consistencyBonus

        // Classify
        let level: TransferIntent.PriorityLevel
        let reasoning: String

        if duration >= Threshold.strongDuration
            && confidence >= Threshold.strongConfidence
            && avgRSSI >= Threshold.strongAvgRSSI {
            level = .strong
            reasoning = "\(duration)s duration, \(String(format: "%.0f", avgRSSI))dBm avg, \(String(format: "%.2f", confidence)) confidence"
        } else if duration >= Threshold.mediumDuration
                    && confidence >= Threshold.mediumConfidence
                    && avgRSSI >= Threshold.mediumAvgRSSI {
            level = .medium
            reasoning = "\(duration)s duration, \(String(format: "%.0f", avgRSSI))dBm avg"
        } else if duration >= Threshold.minimumDuration {
            level = .weak
            reasoning = "\(duration)s duration (brief)"
        } else {
            return nil
        }

        // Resolve identity from ProfileCache
        let cached = ProfileCache.shared.profile(forPrefix: encounter.peerEphemeralId)
        let resolvedName = cached?.name
        let resolvedAvatar = cached?.avatarUrl

        return TransferIntent(
            encounterId: encounter.encounterId,
            peerPrefix: encounter.peerEphemeralId,
            resolvedProfileId: encounter.resolvedProfileId ?? cached?.id,
            resolvedName: resolvedName,
            resolvedAvatarUrl: resolvedAvatar,
            priorityLevel: level,
            eligibleForRelease: level == .strong,
            score: totalScore,
            reasoning: reasoning
        )
    }

    // MARK: - Signal Helpers

    /// Normalized signal quality (0–1) from average RSSI.
    private static func signalQuality(_ avgRSSI: Double) -> Double {
        // -30 dBm = perfect (1.0), -90 dBm = terrible (0.0)
        let clamped = max(-90.0, min(-30.0, avgRSSI))
        return (clamped + 90.0) / 60.0
    }

    /// Signal consistency (0–1) based on the spread between strongest and weakest RSSI.
    /// A narrow spread means the person was consistently at a similar distance.
    private static func signalConsistency(_ encounter: LocalEncounterStore.CapturedEncounter) -> Double {
        let spread = abs(encounter.signalStrengthSummary.strongestRSSI - encounter.signalStrengthSummary.weakestRSSI)
        // 0 spread = perfect consistency (1.0), 40+ spread = poor (0.0)
        if spread <= 5 { return 1.0 }
        if spread <= 15 { return 0.7 }
        if spread <= 25 { return 0.4 }
        return 0.1
    }

    /// Human-readable reason why an encounter was excluded.
    private static func excludeReason(_ encounter: LocalEncounterStore.CapturedEncounter) -> String {
        if encounter.duration < Threshold.minimumDuration {
            return "duration \(encounter.duration)s < \(Threshold.minimumDuration)s minimum"
        }
        if encounter.signalStrengthSummary.sampleCount < Threshold.minimumSamples {
            return "samples \(encounter.signalStrengthSummary.sampleCount) < \(Threshold.minimumSamples) minimum"
        }
        return "below all thresholds"
    }
}
