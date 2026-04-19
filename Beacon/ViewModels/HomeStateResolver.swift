import Foundation
import Combine

// MARK: - Home State

/// The four lifecycle states of the Home intelligence surface.
/// Determines what briefing/context the user sees when feed items are sparse.
enum HomeState: String {
    /// No attendees, not at event, or completely alone
    case preEvent
    /// 1–2 attendees detected, early signals
    case early
    /// Repeated proximity or encounter signals forming
    case emerging
    /// Strong interaction signals, full feed available
    case active
}

// MARK: - Home State Resolver

/// Computes the current HomeState from existing services.
/// Lightweight, reactive, no new data sources.
@MainActor
final class HomeStateResolver: ObservableObject {

    static let shared = HomeStateResolver()

    @Published private(set) var state: HomeState = .preEvent

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    private init() {
        startObserving()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Observation

    private func startObserving() {
        EventJoinService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        EventAttendeesService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        EncounterService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        FeedService.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recalculate() }
            .store(in: &cancellables)

        // Periodic recalculation for time-based transitions
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recalculate() }
        }
    }

    // MARK: - State Computation

    func recalculate() {
        let crowdState = EventCrowdStateResolver.current
        let isAtEvent = EventJoinService.shared.isEventJoined
        let activeEncounters = EncounterService.shared.activeEncounters
        let feedItems = FeedService.shared.feedItems

        // Keep behavior profile fresh alongside state
        BehaviorProfileService.shared.refresh()

        // Not at event and no feed history → preEvent
        if !isAtEvent && feedItems.isEmpty {
            updateState(.preEvent)
            return
        }

        // At event but no attendees → preEvent (you're early)
        if isAtEvent && crowdState == .empty {
            updateState(.preEvent)
            return
        }

        // 1–2 attendees → early
        if isAtEvent && (crowdState == .single || crowdState == .pair) {
            updateState(.early)
            return
        }

        // Check for repeated proximity / encounter signals
        let hasRepeatedEncounters = activeEncounters.values.contains { $0.totalSeconds >= 60 }
        let recentEncounterFeedCount = feedItems.filter { item in
            item.feedType == .encounter &&
            (item.createdAt.map { Date().timeIntervalSince($0) < 3600 } ?? false)
        }.count
        let hasMessageActivity = feedItems.contains { item in
            item.feedType == .message &&
            (item.createdAt.map { Date().timeIntervalSince($0) < 3600 } ?? false)
        }

        // Strong interaction signals → active
        if (recentEncounterFeedCount >= 2 && hasMessageActivity) ||
           (activeEncounters.count >= 3) ||
           (recentEncounterFeedCount >= 3) {
            updateState(.active)
            return
        }

        // Some proximity signals forming → emerging
        if hasRepeatedEncounters || recentEncounterFeedCount >= 1 || activeEncounters.count >= 1 {
            updateState(.emerging)
            return
        }

        // At event with attendees but no interaction signals yet → early
        if isAtEvent {
            updateState(.early)
            return
        }

        // Has feed history but not at event → check density
        if !feedItems.isEmpty {
            let recentItems = feedItems.filter { item in
                item.createdAt.map { Date().timeIntervalSince($0) < 86400 } ?? false
            }
            if recentItems.count >= 3 {
                updateState(.active)
            } else if !recentItems.isEmpty {
                updateState(.emerging)
            } else {
                updateState(.preEvent)
            }
            return
        }

        updateState(.preEvent)
    }

    private func updateState(_ newState: HomeState) {
        if state != newState {
            state = newState
            #if DEBUG
            print("[HomeState] → \(newState.rawValue)")
            #endif
        }
    }

    // MARK: - A. Event Framing

    /// Describes what is happening in the room right now.
    /// Uses real names, counts, and timing — never generic filler.
    var briefingHeadline: String {
        let attendees = EventAttendeesService.shared.attendees
        let encounters = EncounterService.shared.activeEncounters
        let isAtEvent = EventJoinService.shared.isEventJoined

        switch state {
        case .preEvent:
            if isAtEvent {
                return "The room is empty."
            }
            return "No event yet."

        case .early:
            // Name the most recent arrival if possible
            let sorted = attendees.sorted { $0.lastSeen > $1.lastSeen }
            if let newest = sorted.first {
                let name = firstName(newest.name)
                if attendees.count == 1 {
                    return "\(name) just arrived."
                }
                return "\(name) and \(attendees.count - 1) other\(attendees.count == 2 ? "" : "s") are here."
            }
            return "\(attendees.count) people are here."

        case .emerging:
            // Name the strongest proximity signal
            if let top = encounters.max(by: { $0.value.totalSeconds < $1.value.totalSeconds }),
               let attendee = attendees.first(where: { $0.id == top.key }) {
                let name = firstName(attendee.name)
                let mins = top.value.totalSeconds / 60
                if mins >= 3 {
                    return "You and \(name) keep crossing paths."
                }
                return "\(name) is nearby."
            }
            if encounters.count >= 2 {
                return "People are starting to cluster."
            }
            return "Proximity signals are forming."

        case .active:
            let encounterCount = encounters.count
            if encounterCount >= 3 {
                return "\(encounterCount) interactions happening around you."
            }
            if let top = encounters.max(by: { $0.value.totalSeconds < $1.value.totalSeconds }),
               let attendee = attendees.first(where: { $0.id == top.key }) {
                return "Strong signal with \(firstName(attendee.name))."
            }
            return "The room is active."
        }
    }

    /// Supporting context for the event framing.
    var briefingBody: String {
        let attendees = EventAttendeesService.shared.attendees
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let isAtEvent = EventJoinService.shared.isEventJoined

        switch state {
        case .preEvent:
            if isAtEvent {
                return "First arrivals shape the room. Position yourself before it fills."
            }
            return "Scan an event QR code to begin."

        case .early:
            let knownHere = attendees.filter { connectedIds.contains($0.id) }.count
            if knownHere >= 1 {
                let knownNames = attendees
                    .filter { connectedIds.contains($0.id) }
                    .prefix(2)
                    .map { firstName($0.name) }
                return "\(knownNames.joined(separator: " and ")) — you already know \(knownHere == 1 ? "them" : "these people")."
            }
            return "No one you know yet. Early arrivals tend to form the strongest connections."

        case .emerging:
            let encounters = EncounterService.shared.activeEncounters
            let repeatedCount = encounters.values.filter { $0.totalSeconds >= 60 }.count
            if repeatedCount >= 2 {
                return "Repeated encounters are where real connections form."
            }
            return "The room is still taking shape."

        case .active:
            return "Your strongest opportunities are below."
        }
    }

    var briefingIcon: String {
        switch state {
        case .preEvent:  return "sunrise"
        case .early:     return "person.wave.2"
        case .emerging:  return "sparkles"
        case .active:    return "bolt.fill"
        }
    }

    // MARK: - B. For You (Personal Intelligence)

    /// Signal-derived personal intelligence. Uses real names, real data, real evidence.
    /// Priority: relationship → opportunity → gap → timing.
    var forYouLines: [String] {
        var lines: [String] = []
        let attendees = EventAttendeesService.shared.attendees
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let encounters = EncounterService.shared.activeEncounters
        let user = AuthService.shared.currentUser
        let feedItems = FeedService.shared.feedItems
        let isAtEvent = EventJoinService.shared.isEventJoined
        let myId = user?.id

        // 1. Relationship intelligence — prior history with people in the room
        if isAtEvent && !attendees.isEmpty {
            // Check for prior encounters from feed history (not just current BLE)
            let priorEncounterIds = Set(
                feedItems
                    .filter { $0.feedType == .encounter }
                    .compactMap { $0.actorProfileId }
            )

            // People you've encountered before who are here now
            let reEncountered = attendees.filter {
                $0.id != myId && priorEncounterIds.contains($0.id)
            }

            if let strongest = reEncountered.first {
                let name = firstName(strongest.name)
                if let tracker = encounters[strongest.id], tracker.totalSeconds >= 120 {
                    let mins = tracker.totalSeconds / 60
                    lines.append("You've spent \(mins) minutes near \(name) — that's a real signal.")
                } else if connectedIds.contains(strongest.id) {
                    lines.append("You've already connected with \(name) before. This is a continuation.")
                } else {
                    lines.append("You've crossed paths with \(name) before.")
                }
            }

            // Known connections present
            if lines.isEmpty {
                let knownHere = attendees.filter { connectedIds.contains($0.id) }
                if knownHere.count >= 2 {
                    let names = knownHere.prefix(2).map { firstName($0.name) }
                    lines.append("\(names.joined(separator: " and ")) are here — \(knownHere.count) people you know.")
                } else if let known = knownHere.first {
                    lines.append("\(firstName(known.name)) is here — someone from your network.")
                }
            }
        }

        // 2. Opportunity intelligence — real interest overlap with the room
        if isAtEvent && lines.count < 2 {
            let userInterests = Set((user?.interests ?? []).map { $0.lowercased() })
            let userSkills = Set((user?.skills ?? []).map { $0.lowercased() })
            let userAnchors = userInterests.union(userSkills)

            // Build room interest profile from actual attendee data
            var roomInterests: [String: Int] = [:]
            for attendee in attendees {
                guard attendee.id != myId else { continue }
                for interest in attendee.interests ?? [] {
                    roomInterests[interest.lowercased(), default: 0] += 1
                }
            }

            // Find real overlap
            let overlap = roomInterests
                .filter { userAnchors.contains($0.key) }
                .sorted { $0.value > $1.value }

            if overlap.count >= 2 {
                let themes = overlap.prefix(2).map { $0.key }
                lines.append("This room has \(overlap.first!.value + (overlap.dropFirst().first?.value ?? 0)) people who share your \(themes.joined(separator: " and ")) interests.")
            } else if let top = overlap.first, top.value >= 2 {
                lines.append("\(top.value) people here share your interest in \(top.key).")
            } else if overlap.isEmpty && !userAnchors.isEmpty && attendees.count >= 3 {
                lines.append("Low overlap with your interests — this could expand your network in new directions.")
            }
        }

        // 3. Timing intelligence — what your actual behavior patterns suggest
        if lines.count < 2 {
            let traits = DynamicProfileService.shared.earnedTraits
            let signals = DynamicProfileService.shared.currentSignals

            if let followThrough = traits.first(where: { $0.id == "follows-through" }) {
                lines.append("You've followed up \(followThrough.evidenceCount) times after events — that pattern is working.")
            } else if let themeTrait = traits.first(where: { $0.id == "theme-driven" }) {
                lines.append("Your activity around \(themeTrait.publicText.replacingOccurrences(of: "Active around ", with: "").replacingOccurrences(of: " conversations", with: "")) keeps growing.")
            } else if let behaviorInsight = BehaviorProfileService.shared.bestInsight {
                // Behavior-derived insight from observed patterns
                lines.append(behaviorInsight)
            } else if signals.hasFollowUpMomentum {
                lines.append("Your recent follow-up activity suggests repeated encounters matter for you.")
            }
        }

        // 4. Gap intelligence — when there's genuinely nothing
        if lines.isEmpty {
            let connectionCount = feedItems.filter { $0.feedType == .connection }.count
            if connectionCount >= 3 {
                lines.append("\(connectionCount) connections in your network. Each event adds to that.")
            } else if connectionCount >= 1 {
                lines.append("Your network is starting to form. Repeated presence builds trust.")
            }
        }

        return Array(lines.prefix(2))
    }

    // MARK: - C. Best Move (Signal-Derived)

    /// Derived from actual signals — not pre-written advice.
    /// Reads encounters, connections, attendees, and traits to compose a recommendation.
    var bestMoveLines: [String] {
        var lines: [String] = []
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let attendees = EventAttendeesService.shared.attendees
        let encounters = EncounterService.shared.activeEncounters
        let traits = DynamicProfileService.shared.earnedTraits
        let isAtEvent = EventJoinService.shared.isEventJoined
        let myId = AuthService.shared.currentUser?.id

        let knownHere = isAtEvent ? attendees.filter { connectedIds.contains($0.id) }.count : 0

        // Find the strongest current encounter
        let topEncounter = encounters
            .filter { $0.key != myId }
            .max(by: { $0.value.totalSeconds < $1.value.totalSeconds })
        let topAttendeeName = topEncounter.flatMap { enc in
            attendees.first(where: { $0.id == enc.key })
        }.map { firstName($0.name) }

        // Find repeated encounters (>60s)
        let repeatedEncounters = encounters.values.filter { $0.totalSeconds >= 60 }

        switch state {
        case .preEvent:
            if isAtEvent {
                if traits.contains(where: { $0.id == "follows-through" }) {
                    lines.append("You convert early arrivals well. Use the quiet to set up conversations.")
                } else {
                    lines.append("The room is yours to shape. Move around and claim space.")
                }
            } else {
                lines.append("Scan an event QR to begin.")
            }

        case .early:
            if knownHere >= 1, let known = attendees.first(where: { connectedIds.contains($0.id) }) {
                let behavior = BehaviorProfileService.shared.confidentTendencies
                if behavior.contains(where: { $0.id == "familiar-first" }) {
                    lines.append("\(firstName(known.name)) is here — and you tend to start with familiar faces.")
                } else {
                    lines.append("\(firstName(known.name)) is already here — that's your easiest starting point.")
                }
            } else if let name = topAttendeeName {
                lines.append("\(name) is the closest signal. Early conversations tend to stick.")
            } else {
                if BehaviorProfileService.shared.confidentTendencies.contains(where: { $0.id == "late-engager" }) {
                    lines.append("You tend to engage later. No rush — let the room fill in.")
                } else {
                    lines.append("Few people, high signal. Each interaction carries more weight right now.")
                }
            }

        case .emerging:
            let behavior = BehaviorProfileService.shared.confidentTendencies
            if repeatedEncounters.count >= 2 {
                let names = repeatedEncounters.prefix(2).compactMap { enc in
                    attendees.first(where: { $0.id == enc.profileId })
                }.map { firstName($0.name) }
                if names.count >= 2 {
                    lines.append("You keep crossing paths with \(names.joined(separator: " and ")) — that's where value is forming.")
                } else if let name = names.first {
                    if behavior.contains(where: { $0.id == "repeat-encounters" }) {
                        lines.append("You and \(name) keep ending up near each other — and your pattern shows repeat encounters convert.")
                    } else {
                        lines.append("You and \(name) keep ending up near each other. Worth a conversation.")
                    }
                }
            } else if let name = topAttendeeName, let enc = topEncounter {
                let mins = enc.value.totalSeconds / 60
                if mins >= 2 {
                    lines.append("\(name) has been nearby for \(mins) minutes — easiest to build on.")
                } else if behavior.contains(where: { $0.id == "explorer" }) {
                    lines.append("Signal with \(name) is forming. Your pattern is to explore first — keep moving.")
                } else {
                    lines.append("Proximity with \(name) is forming. See if it repeats before committing.")
                }
            } else {
                if behavior.contains(where: { $0.id == "depth-seeker" }) {
                    lines.append("Signals forming but nothing deep yet. Wait for one to strengthen.")
                } else {
                    lines.append("Signals are forming but nothing has repeated yet. Keep moving.")
                }
            }

        case .active:
            if let name = topAttendeeName, let enc = topEncounter, enc.value.totalSeconds >= 180 {
                if connectedIds.contains(enc.key) {
                    lines.append("You and \(name) have strong signal and a connection. Deepen it.")
                } else {
                    lines.append("\(name) is your strongest signal right now. This is worth acting on.")
                }
            }
            if traits.contains(where: { $0.id == "follows-through" }) && lines.count < 2 {
                lines.append("Your follow-through is strong. Make sure to message the people who matter after this.")
            }
            if encounters.count >= 3 && lines.count < 2 {
                lines.append("Multiple signals competing. Focus on the one that's repeated most.")
            }
        }

        if lines.isEmpty {
            // Try behavior-derived recommendation before generic fallback
            if let behaviorRec = BehaviorProfileService.shared.bestRecommendation {
                lines.append(behaviorRec)
            } else if isAtEvent {
                lines.append("No strong signal yet. Keep moving until something repeats.")
            } else {
                lines.append("Join an event to start reading the room.")
            }
        }

        return Array(lines.prefix(2))
    }

    // MARK: - Helpers

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}
