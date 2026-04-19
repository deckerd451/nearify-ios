import Foundation

// MARK: - Decision Surface Output Model

/// UI-ready decision surface for live event interaction.
/// Produced by DecisionSurfaceAdapter from interactionScore(person).
/// Consumed by views — never by scoring or backend logic.
struct DecisionSurface {
    let primary: PersonSurface?
    let alternatives: [PersonSurface]
    let context: EventSurfaceContext
}

struct PersonSurface: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let strength: Double            // 0.0–1.0, relative to current set
    let signals: [SignalTag]        // max 3
    let action: DecisionActionType
    let interactionState: InteractionState
    let proximityHint: String?
}

struct SignalTag: Identifiable {
    let id = UUID()
    let type: SignalType
    let label: String
}

enum SignalType: String {
    case proximity
    case duration
    case recency
    case repeats
    case relationship
    case interest
}

enum DecisionActionType: String {
    case goSayHi    = "go_say_hi"
    case find       = "find"
    case navigate   = "navigate"
    case followUp   = "follow_up"
    case viewProfile = "view_profile"

    var label: String {
        switch self {
        case .goSayHi:    return "Go say hi"
        case .find:       return "Find"
        case .navigate:   return "Navigate"
        case .followUp:   return "Follow up"
        case .viewProfile: return "View profile"
        }
    }

    var icon: String {
        switch self {
        case .goSayHi:    return "hand.wave"
        case .find:       return "location"
        case .navigate:   return "arrow.triangle.turn.up.right.diamond"
        case .followUp:   return "bubble.left"
        case .viewProfile: return "person"
        }
    }
}

enum InteractionState: String {
    case notMet     = "not_met"
    case inProgress = "in_progress"
    case met        = "met"
}

enum EventPhase: String {
    case early
    case mid
    case late
}

struct EventSurfaceContext {
    let totalPeopleHere: Int
    let metCount: Int
    let phase: EventPhase
}

// MARK: - Decision Surface Adapter
//
// Thin adapter layer. Consumes existing people + interactionScore(person).
// Outputs a structured DecisionSurface. No new scoring logic.

@MainActor
enum DecisionSurfaceAdapter {

    /// Builds a DecisionSurface from current live event state.
    /// All ranking comes from InteractionScorer.score() — no parallel heuristics.
    /// The authenticated user is always excluded from all candidate lists.
    static func buildDecisionSurface() -> DecisionSurface {
        let attendees = EventAttendeesService.shared.attendees
        let encounters = EncounterService.shared.activeEncounters
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })

        // Current user's profile ID — required for self-exclusion.
        // If unavailable, return empty surface rather than risk showing self.
        guard let currentProfileId = AuthService.shared.currentUser?.id else {
            #if DEBUG
            print("[DecisionSurface] ⚠️ No authenticated user — returning empty surface")
            #endif
            return DecisionSurface(
                primary: nil, alternatives: [],
                context: EventSurfaceContext(totalPeopleHere: 0, metCount: 0, phase: .early)
            )
        }

        // BLE prefix set for proximity detection
        let bleDevices = BLEScannerService.shared.getFilteredDevices()
        var blePrefixes = Set<String>()
        for device in bleDevices where device.name.hasPrefix("BCN-") {
            if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                blePrefixes.insert(prefix)
            }
        }

        let relById = Dictionary(uniqueKeysWithValues: relationships.map { ($0.profileId, $0) })

        // ── Score every visible person (excluding self) ──
        var scored: [ScoredPerson] = []

        // From live attendees
        for attendee in attendees {
            guard attendee.id != currentProfileId else { continue }
            let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
            let isBLE = blePrefixes.contains(prefix)
            let rel = relById[attendee.id]
            let encounter = encounters[attendee.id]

            let signals: InteractionScorer.Signals
            if let rel {
                signals = InteractionScorer.signals(
                    for: rel, encounter: encounter,
                    bleDetected: isBLE,
                    heartbeatLive: attendee.isHereNow,
                    myInterests: myInterests
                )
            } else {
                signals = InteractionScorer.signals(
                    for: attendee, encounter: encounter,
                    bleDetected: isBLE,
                    connectedIds: connectedIds,
                    myInterests: myInterests
                )
            }

            let s = InteractionScorer.score(signals)
            scored.append(ScoredPerson(
                id: attendee.id,
                name: attendee.name,
                avatarUrl: attendee.avatarUrl,
                score: s,
                signals: signals,
                rel: rel,
                attendee: attendee
            ))
        }

        // Also include BLE-detected relationships not in attendee list
        for rel in relationships {
            guard rel.profileId != currentProfileId else { continue }
            guard !scored.contains(where: { $0.id == rel.profileId }) else { continue }
            let prefix = String(rel.profileId.uuidString.prefix(8)).lowercased()
            guard blePrefixes.contains(prefix) else { continue }

            let encounter = encounters[rel.profileId]
            let signals = InteractionScorer.signals(
                for: rel, encounter: encounter,
                bleDetected: true,
                heartbeatLive: false,
                myInterests: myInterests
            )
            let s = InteractionScorer.score(signals)
            scored.append(ScoredPerson(
                id: rel.profileId,
                name: rel.name,
                avatarUrl: rel.avatarUrl,
                score: s,
                signals: signals,
                rel: rel,
                attendee: nil
            ))
        }

        // Sort by interactionScore descending
        scored.sort { $0.score > $1.score }

        let maxScore = scored.first?.score ?? 0

        // ── Event context ──
        let metCount = scored.filter { p in
            let enc = encounters[p.id]
            return (enc?.totalSeconds ?? 0) >= 30 || connectedIds.contains(p.id)
        }.count

        let context = EventSurfaceContext(
            totalPeopleHere: scored.count,
            metCount: metCount,
            phase: resolvePhase(attendeeCount: scored.count, metCount: metCount)
        )

        // ── Empty state ──
        guard let top = scored.first, top.score > 0 else {
            return DecisionSurface(primary: nil, alternatives: [], context: context)
        }

        // ── Primary (with defensive self-exclusion guard) ──
        let primaryCandidate: ScoredPerson
        if top.id == currentProfileId {
            // Defensive: self slipped through filters — skip to next
            #if DEBUG
            print("[DecisionSurface] ⚠️ Self appeared as top candidate — discarding")
            #endif
            guard let next = scored.dropFirst().first(where: { $0.id != currentProfileId && $0.score > 0 }) else {
                return DecisionSurface(primary: nil, alternatives: [], context: context)
            }
            primaryCandidate = next
        } else {
            primaryCandidate = top
        }

        let primary = buildPersonSurface(
            primaryCandidate, maxScore: maxScore, encounters: encounters, connectedIds: connectedIds
        )

        // ── Alternatives (score >= 0.7 × primary, max 2, excluding self) ──
        let threshold = primaryCandidate.score * 0.7
        let alts = scored
            .filter { $0.id != primaryCandidate.id && $0.id != currentProfileId && $0.score >= threshold }
            .prefix(2)
            .map { buildPersonSurface($0, maxScore: maxScore, encounters: encounters, connectedIds: connectedIds) }

        return DecisionSurface(
            primary: primary,
            alternatives: Array(alts),
            context: context
        )
    }

    // MARK: - Person Surface Builder

    private static func buildPersonSurface(
        _ p: ScoredPerson,
        maxScore: Double,
        encounters: [UUID: EncounterTracker],
        connectedIds: Set<UUID>
    ) -> PersonSurface {
        let strength = maxScore > 0 ? p.score / maxScore : 0

        let tags = buildSignalTags(p.signals, rel: p.rel)
        let action = resolveAction(p.signals)
        let state = resolveInteractionState(p.signals, connectedIds: connectedIds, personId: p.id)
        let hint = resolveProximityHint(p.signals)

        return PersonSurface(
            id: p.id,
            name: p.name,
            avatarUrl: p.avatarUrl,
            strength: strength,
            signals: tags,
            action: action,
            interactionState: state,
            proximityHint: hint
        )
    }

    // MARK: - Signal Tags (max 3, strongest contributors)

    private static func buildSignalTags(
        _ s: InteractionScorer.Signals,
        rel: RelationshipMemory?
    ) -> [SignalTag] {
        // Collect candidate tags with their contributing weight
        var candidates: [(weight: Double, tag: SignalTag)] = []

        // Proximity
        let proxScore = InteractionScorer.proximityScore(s)
        if proxScore > 0 {
            let label = s.isBLEDetected ? "nearby" : "at event"
            candidates.append((proxScore * 0.35, SignalTag(type: .proximity, label: label)))
        }

        // Duration
        let durScore = InteractionScorer.durationScore(s)
        if durScore > 0 {
            let secs = max(s.encounterSeconds, s.historicalOverlapSeconds)
            let mins = secs / 60
            let label = mins >= 1 ? "\(mins) min together" : "\(secs)s nearby"
            candidates.append((durScore * 0.30, SignalTag(type: .duration, label: label)))
        }

        // Recency
        let recScore = InteractionScorer.recencyScore(s)
        if recScore >= 0.7 {
            let label = recScore >= 1.0 ? "just now" : "recent"
            candidates.append((recScore * 0.15, SignalTag(type: .recency, label: label)))
        }

        // Repeats
        let repScore = InteractionScorer.repeatScore(s)
        if repScore > 0 {
            let label = s.encounterCount >= 3 ? "seen \(s.encounterCount)×" : "seen \(s.encounterCount)×"
            candidates.append((repScore * 0.10, SignalTag(type: .repeats, label: label)))
        }

        // Relationship
        if s.isConnected {
            candidates.append((0.10, SignalTag(type: .relationship, label: "connected")))
        } else if s.hasConversation {
            candidates.append((0.08, SignalTag(type: .relationship, label: "messaged")))
        }

        // Shared interests
        if s.sharedInterestCount > 0 {
            if let interest = rel?.sharedInterests.first {
                candidates.append((Double(s.sharedInterestCount) * 0.03, SignalTag(type: .interest, label: "shared: \(interest)")))
            } else {
                candidates.append((Double(s.sharedInterestCount) * 0.03, SignalTag(type: .interest, label: "\(s.sharedInterestCount) shared interest\(s.sharedInterestCount == 1 ? "" : "s")")))
            }
        }

        // Sort by weight, take top 3
        candidates.sort { $0.weight > $1.weight }
        return Array(candidates.prefix(3).map(\.tag))
    }

    // MARK: - Action Resolution (from signals only)

    private static func resolveAction(_ s: InteractionScorer.Signals) -> DecisionActionType {
        // Very close BLE → go say hi
        if s.isBLEDetected && s.isHeartbeatLive {
            return .goSayHi
        }
        // BLE detected but no heartbeat → find
        if s.isBLEDetected {
            return .find
        }
        // Heartbeat live, no BLE → navigate
        if s.isHeartbeatLive {
            return .navigate
        }
        // Has meaningful interaction history → follow up
        if s.isConnected || s.hasConversation || s.encounterSeconds >= 60 {
            return .followUp
        }
        // Weak signal → view profile
        return .viewProfile
    }

    // MARK: - Interaction State

    private static func resolveInteractionState(
        _ s: InteractionScorer.Signals,
        connectedIds: Set<UUID>,
        personId: UUID
    ) -> InteractionState {
        if connectedIds.contains(personId) || s.hasConversation {
            return .met
        }
        if s.encounterSeconds >= 30 || s.historicalOverlapSeconds >= 30 {
            return .inProgress
        }
        return .notMet
    }

    // MARK: - Proximity Hint

    private static func resolveProximityHint(_ s: InteractionScorer.Signals) -> String? {
        if s.isBLEDetected && s.isHeartbeatLive { return "Very close" }
        if s.isBLEDetected { return "Nearby" }
        if s.isHeartbeatLive { return "At event" }
        return nil
    }

    // MARK: - Event Phase

    private static func resolvePhase(attendeeCount: Int, metCount: Int) -> EventPhase {
        let crowdState = EventCrowdStateResolver.current
        switch crowdState {
        case .empty, .single, .pair:
            return .early
        case .group:
            if metCount >= attendeeCount / 2 { return .late }
            return .mid
        }
    }

    // MARK: - Scored Person (internal)

    private struct ScoredPerson {
        let id: UUID
        let name: String
        let avatarUrl: String?
        let score: Double
        let signals: InteractionScorer.Signals
        let rel: RelationshipMemory?
        let attendee: EventAttendee?
    }
}
