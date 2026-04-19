import Foundation

// MARK: - Decision Type
//
// Strict priority order. Only ONE may be primary at any time.
// The app answers: "What should I do right now?"

enum DecisionType: String {
    /// Person physically near, inside event. Strongest signal.
    case liveInteraction
    /// Rejoinable event exists with meaningful history.
    case rejoinEvent
    /// Strong past relationship worth reconnecting.
    case reconnect
    /// High-potential new connection at current event.
    case meetNew
    /// No strong signals. Guide user to find an event.
    case explore
}

// MARK: - Primary Decision
//
// The single decision the app presents to the user.
// Resolved BEFORE any UI renders. Only one exists at a time.

struct PrimaryDecision {
    let type: DecisionType
    let eventName: String?
    let eventId: String?
    let personName: String?
    let personId: UUID?
    let personAvatarUrl: String?
    let confidence: Double
    let headline: String
    let contextLine: String?    // Line 1: current context ("Here now", "You met at…")
    let whyNowLine: String?     // Line 2: why now ("You were just near each other")
    let subtext: String?
    let primaryAction: String
    let secondaryAction: String?
}

// MARK: - Decision Resolver
//
// Reads existing service state. No new data sources.
// Returns exactly ONE decision. No fallback stacking.

@MainActor
enum DecisionResolver {

    static func resolve() -> PrimaryDecision {
        let eventJoin = EventJoinService.shared
        let presence = UserPresenceStateResolver.current
        let meetSuggestion = MeetSuggestionService.shared
        let relationships = RelationshipMemoryService.shared.relationships
        let attendees = EventAttendeesService.shared.attendees
        let encounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds

        // Current user's profile ID — required for self-exclusion.
        // If unavailable, fall through to explore state.
        let myId = AuthService.shared.currentUser?.id ?? UUID()

        // ── 1. LIVE INTERACTION ──
        // State-aware: behaviour changes based on attendee count.
        //   0 attendees  → empty  (solo, preview network)
        //   1–2 attendees → early  (name the person, go say hi)
        //   3+ attendees  → active (count + "Start here" recommendation)
        if eventJoin.isEventJoined {
            let eventName = eventJoin.currentEventName ?? "Event"
            let crowdState = EventCrowdStateResolver.current
            let attendeeCount = EventCrowdStateResolver.count

            // ── EMPTY (0 attendees) ──
            if crowdState == .empty {
                return PrimaryDecision(
                    type: .liveInteraction,
                    eventName: eventName,
                    eventId: eventJoin.currentEventID,
                    personName: nil,
                    personId: nil,
                    personAvatarUrl: nil,
                    confidence: presence == .insideEvent ? 0.8 : 0.4,
                    headline: "You're the first one here 👋",
                    contextLine: nil,
                    whyNowLine: nil,
                    subtext: "Others will appear as they arrive",
                    primaryAction: "Preview your network",
                    secondaryAction: nil
                )
            }

            // ── SINGLE or PAIR (1–2 attendees) ──
            if crowdState == .single || crowdState == .pair {
                let liveOthers = attendees.filter { $0.id != myId && $0.isHereNow }
                let target = bestLiveTarget(attendees: attendees, encounters: encounters, myId: myId)
                    ?? liveOthers.first!

                return PrimaryDecision(
                    type: .liveInteraction,
                    eventName: eventName,
                    eventId: eventJoin.currentEventID,
                    personName: target.name,
                    personId: target.id,
                    personAvatarUrl: target.avatarUrl,
                    confidence: presence == .insideEvent ? 0.9 : 0.6,
                    headline: "\(firstName(target.name)) is here",
                    contextLine: "Go say hi",
                    whyNowLine: attendeeCount == 2
                        ? "\(attendeeCount) people here — early conversations stick"
                        : "Just the two of you — easy intro",
                    subtext: nil,
                    primaryAction: "Find them",
                    secondaryAction: "Preview your network"
                )
            }

            // ── GROUP (3+ attendees) ──
            // Pick the best "Start here" recommendation.
            let liveOthers = attendees.filter { $0.id != myId && $0.isHereNow }
            let startHere = bestLiveTarget(attendees: attendees, encounters: encounters, myId: myId)
                ?? liveOthers.first!

            let overlapMins = (encounters[startHere.id]?.totalSeconds ?? 0) / 60
            let isConnected = connectedIds.contains(startHere.id)

            // Build a short reason for the recommendation
            let reason: String
            if isConnected && overlapMins >= 2 {
                reason = "Already connected · near you now"
            } else if isConnected {
                reason = "Someone you know — easy starting point"
            } else if overlapMins >= 3 {
                reason = "You've been near each other for \(overlapMins) min"
            } else {
                // Derive from shared interests if available
                let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })
                let theirInterests = Set((startHere.interests ?? []).map { $0.lowercased() })
                let shared = myInterests.intersection(theirInterests)
                if let topic = shared.first {
                    reason = "You both share an interest in \(topic)"
                } else {
                    reason = "Strongest signal in the room"
                }
            }

            return PrimaryDecision(
                type: .liveInteraction,
                eventName: eventName,
                eventId: eventJoin.currentEventID,
                personName: startHere.name,
                personId: startHere.id,
                personAvatarUrl: startHere.avatarUrl,
                confidence: presence == .insideEvent ? 0.95 : 0.7,
                headline: "\(attendeeCount) people are here",
                contextLine: "Start with \(firstName(startHere.name))",
                whyNowLine: reason,
                subtext: nil,
                primaryAction: "Find them",
                secondaryAction: "View everyone"
            )
        }

        // ── 2. REJOIN EVENT ──
        if let ctx = eventJoin.reconnectContext {
            return PrimaryDecision(
                type: .rejoinEvent,
                eventName: ctx.eventName,
                eventId: ctx.eventId,
                personName: nil,
                personId: nil,
                personAvatarUrl: nil,
                confidence: 0.6,
                headline: "Back at \(ctx.eventName)?",
                contextLine: nil,
                whyNowLine: nil,
                subtext: nil,
                primaryAction: "Rejoin Event",
                secondaryAction: "Browse Events"
            )
        }

        // ── 3. RECONNECT ──
        if let strongest = relationships.first, strongest.relationshipStrength > 0.3 {
            // Line 1: current context
            let contextLine: String
            if let event = strongest.eventContexts.first {
                contextLine = "You met at \(event)"
            } else if strongest.connectionStatus == .accepted {
                contextLine = "You're already connected"
            } else {
                contextLine = "\(strongest.encounterCount) encounter\(strongest.encounterCount == 1 ? "" : "s") together"
            }

            // Line 2: why now
            let whyNowLine: String
            if strongest.needsFollowUp {
                whyNowLine = "Worth following up before the moment passes"
            } else if strongest.hasConversation {
                whyNowLine = "You already have momentum"
            } else {
                whyNowLine = "A strong connection to keep building"
            }

            return PrimaryDecision(
                type: .reconnect,
                eventName: strongest.eventContexts.first,
                eventId: nil,
                personName: strongest.name,
                personId: strongest.profileId,
                personAvatarUrl: strongest.avatarUrl,
                confidence: strongest.relationshipStrength,
                headline: firstName(strongest.name),
                contextLine: contextLine,
                whyNowLine: whyNowLine,
                subtext: nil,
                primaryAction: strongest.hasConversation ? "Message" : "Connect",
                secondaryAction: "View profile"
            )
        }

        // ── 4. MEET NEW ──
        if let candidate = meetSuggestion.candidates.first {
            // Line 1: current context
            let contextLine = candidate.descriptor.isEmpty
                ? "At this event now"
                : candidate.descriptor

            // Line 2: why now
            let whyNowLine = candidate.explanation

            return PrimaryDecision(
                type: .meetNew,
                eventName: eventJoin.currentEventName,
                eventId: eventJoin.currentEventID,
                personName: candidate.name,
                personId: candidate.id,
                personAvatarUrl: candidate.avatarUrl,
                confidence: candidate.score / 20.0,
                headline: "Meet \(firstName(candidate.name))",
                contextLine: contextLine,
                whyNowLine: whyNowLine,
                subtext: nil,
                primaryAction: "Go say hi",
                secondaryAction: "View profile"
            )
        }

        // ── 5. EXPLORE ──
        return PrimaryDecision(
            type: .explore,
            eventName: nil,
            eventId: nil,
            personName: nil,
            personId: nil,
            personAvatarUrl: nil,
            confidence: 0.0,
            headline: "You're at an event?",
            contextLine: nil,
            whyNowLine: nil,
            subtext: nil,
            primaryAction: "Scan Event QR",
            secondaryAction: "Browse Events"
        )
    }

    // MARK: - Helpers

    /// Selects the single best live target from current attendees.
    /// Uses the unified InteractionScorer for consistent ranking.
    private static func bestLiveTarget(
        attendees: [EventAttendee],
        encounters: [UUID: EncounterTracker],
        myId: UUID?
    ) -> EventAttendee? {
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })
        let bleDetectedPrefixes = currentBLEPrefixes()

        let candidates = attendees.filter { $0.id != myId && $0.isHereNow }
        guard !candidates.isEmpty else { return nil }

        return candidates
            .map { attendee -> (EventAttendee, Double) in
                let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
                let signals = InteractionScorer.signals(
                    for: attendee,
                    encounter: encounters[attendee.id],
                    bleDetected: bleDetectedPrefixes.contains(prefix),
                    connectedIds: connectedIds,
                    myInterests: myInterests
                )
                return (attendee, InteractionScorer.score(signals))
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// Returns the current set of BCN- prefixes visible via BLE.
    private static func currentBLEPrefixes() -> Set<String> {
        let devices = BLEScannerService.shared.getFilteredDevices()
        var prefixes = Set<String>()
        for device in devices where device.name.hasPrefix("BCN-") {
            if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                prefixes.insert(prefix)
            }
        }
        return prefixes
    }

    private static func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}
