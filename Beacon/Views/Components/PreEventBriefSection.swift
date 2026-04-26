import SwiftUI

// MARK: - Event Brief Model

/// Structured briefing data for the Home screen.
/// Each section is optional — only populated sections render.
/// `startHere` is the primary decision section and renders first.
struct EventBrief {
    let startHere: [ArrivalTarget]
    let hereNow: [BriefPerson]
    let likelyAttendees: [BriefPerson]
    let suggestedConnections: [BriefConnection]
    let talkingPoints: [String]

    var isEmpty: Bool {
        startHere.isEmpty && hereNow.isEmpty && likelyAttendees.isEmpty
        && suggestedConnections.isEmpty && talkingPoints.isEmpty
    }
}

/// A prioritized target for the "Start Here" section.
/// Always has a reason — never empty when attendees exist.
struct ArrivalTarget: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let reason: String
}

struct BriefPerson: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let descriptor: String  // e.g. "AI + startups"
}

struct BriefConnection: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let whyTheyMatter: String   // why THEY matter to YOU
    let whyYouMatter: String    // why YOU matter to THEM
}

// Keep BriefTarget for backward compatibility if referenced elsewhere
struct BriefTarget: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let reason: String
}

// MARK: - Event Brief View

/// Renders the Event Brief above the Decision Surface.
/// Compact, scannable, no CTA buttons — tap-to-profile only.
/// Sections with no data are omitted entirely.
struct EventBriefView: View {
    let brief: EventBrief
    let onTapProfile: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── 0. START HERE (primary decision section) ──
            if !brief.startHere.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("START HERE")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.green.opacity(0.8))
                        .tracking(1.0)

                    ForEach(brief.startHere) { target in
                        Button {
                            onTapProfile(target.id)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    imageUrl: target.avatarUrl,
                                    name: target.name,
                                    size: 38,
                                    placeholderColor: .green
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.green.opacity(0.3), lineWidth: 1.5)
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(firstName(target.name))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)

                                    Text(target.reason)
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.55))
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                        }
                    }
                }
            }

            // ── 1. HERE NOW ──
            if !brief.hereNow.isEmpty {
                briefSection(title: "HERE NOW", color: .green) {
                    ForEach(brief.hereNow) { person in
                        personRow(person, color: .green)
                    }
                }
            }

            // ── 2. LIKELY ATTENDEES ──
            if !brief.likelyAttendees.isEmpty {
                briefSection(title: "LIKELY HERE", color: .cyan.opacity(0.7)) {
                    ForEach(brief.likelyAttendees) { person in
                        personRow(person, color: .cyan.opacity(0.7))
                    }
                }
            }

            // ── 3. SUGGESTED CONNECTIONS ──
            if !brief.suggestedConnections.isEmpty {
                briefSection(title: "SUGGESTED CONNECTIONS", color: .orange) {
                    ForEach(brief.suggestedConnections) { conn in
                        connectionRow(conn)
                    }
                }
            }

            // ── 4. TALKING POINTS ──
            if !brief.talkingPoints.isEmpty {
                briefSection(title: "TALKING POINTS", color: .white.opacity(0.3)) {
                    ForEach(Array(brief.talkingPoints.enumerated()), id: \.offset) { _, point in
                        Text(point)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Section Container

    private func briefSection<Content: View>(
        title: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color.opacity(0.6))
                .tracking(0.8)

            content()
        }
    }

    // MARK: - Person Row (Here Now / Likely)

    private func personRow(_ person: BriefPerson, color: Color) -> some View {
        Button {
            onTapProfile(person.id)
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    imageUrl: person.avatarUrl,
                    name: person.name,
                    size: 30,
                    placeholderColor: color
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(firstName(person.name))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.8))

                    if !person.descriptor.isEmpty {
                        Text(person.descriptor)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Connection Row (Suggested)

    private func connectionRow(_ conn: BriefConnection) -> some View {
        Button {
            onTapProfile(conn.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(
                    imageUrl: conn.avatarUrl,
                    name: conn.name,
                    size: 30,
                    placeholderColor: .orange
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(firstName(conn.name))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.8))

                    Text(conn.whyTheyMatter)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)

                    Text(conn.whyYouMatter)
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()
            }
        }
    }

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}

// MARK: - Merged Presence
//
// Combines backend attendees + BLE-detected relationships into a single
// "visible people" list. This is the same merge logic used by
// PeopleIntelligenceBuilder and DecisionSurfaceAdapter.
// BLE presence is sufficient — no backend confirmation required.

@MainActor
struct MergedAttendee {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let interests: [String]?
    let skills: [String]?
    let isHereNow: Bool
    let source: PresenceSource
}

@MainActor
enum MergedPresenceBuilder {

    static func build(myId: UUID) -> [MergedAttendee] {
        let attendees = EventAttendeesService.shared.attendees
        let relationships = RelationshipMemoryService.shared.relationships

        // BLE prefix set
        let bleDevices = BLEScannerService.shared.getFilteredDevices()
        var blePrefixes = Set<String>()
        for device in bleDevices where device.name.hasPrefix("BCN-") {
            if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                blePrefixes.insert(prefix)
            }
        }

        var result: [MergedAttendee] = []
        var seenIds = Set<UUID>()

        // 1. Backend attendees (with BLE enrichment)
        for attendee in attendees where attendee.id != myId {
            seenIds.insert(attendee.id)
            let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
            let isBLE = blePrefixes.contains(prefix)
            let source: PresenceSource = isBLE ? .bleAndBackend : .backend

            result.append(MergedAttendee(
                id: attendee.id, name: attendee.name,
                avatarUrl: attendee.avatarUrl,
                interests: attendee.interests, skills: attendee.skills,
                isHereNow: attendee.isHereNow || isBLE,
                source: source
            ))
        }

        // 2. BLE-only people from relationships (not in backend list yet)
        for rel in relationships where rel.profileId != myId && !seenIds.contains(rel.profileId) {
            let prefix = String(rel.profileId.uuidString.prefix(8)).lowercased()
            guard blePrefixes.contains(prefix) else { continue }

            seenIds.insert(rel.profileId)
            result.append(MergedAttendee(
                id: rel.profileId, name: rel.name,
                avatarUrl: rel.avatarUrl,
                interests: nil, skills: nil,  // relationship doesn't carry these
                isHereNow: true,
                source: .ble
            ))
        }

        #if DEBUG
        let bleOnly = result.filter { $0.source == .ble }.count
        let backendOnly = result.filter { $0.source == .backend }.count
        let both = result.filter { $0.source == .bleAndBackend }.count
        print("[MergedPresence] total=\(result.count) ble=\(bleOnly) backend=\(backendOnly) both=\(both)")
        #endif

        return result
    }
}

// MARK: - Event Brief Builder

/// Builds the EventBrief from existing service state.
/// Uses InteractionScorer for ranking — no new scoring logic.
/// No backend calls — reads from already-loaded services.
@MainActor
enum EventBriefBuilder {

    static func build(crowdState: EventCrowdState) -> EventBrief {
        guard let myId = AuthService.shared.currentUser?.id else {
            return EventBrief(startHere: [], hereNow: [], likelyAttendees: [], suggestedConnections: [], talkingPoints: [])
        }

        let mergedPeople = MergedPresenceBuilder.build(myId: myId)
        let encounters = EncounterService.shared.activeEncounters
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })
        let mySkills = Set((AuthService.shared.currentUser?.skills ?? []).map { $0.lowercased() })
        let eventName = EventJoinService.shared.currentEventName ?? ""

        let relById = Dictionary(uniqueKeysWithValues: relationships.map { ($0.profileId, $0) })
        let mergedIds = Set(mergedPeople.map(\.id))

        let limit: Int = {
            switch crowdState {
            case .empty: return 0
            case .single: return 1
            case .pair: return 2
            case .group: return 3
            }
        }()

        // ── 0. START HERE (always attempted when attendees exist) ──
        let startHere = ArrivalTargetBuilder.build(limit: min(limit, 2))

        // Track claimed IDs to prevent any person appearing in multiple sections.
        // Priority order: START HERE > HERE NOW > LIKELY HERE > SUGGESTED.
        var claimedIds = Set(startHere.map(\.id))

        // ── 1. HERE NOW ──
        var hereNow: [BriefPerson] = []

        for person in mergedPeople where person.isHereNow {
            guard hereNow.count < limit else { break }
            guard !claimedIds.contains(person.id) else { continue }
            let descriptor = buildDescriptorFromMerged(
                person: person, rel: relById[person.id],
                myInterests: myInterests, mySkills: mySkills
            )
            hereNow.append(BriefPerson(
                id: person.id, name: person.name,
                avatarUrl: person.avatarUrl, descriptor: descriptor
            ))
            claimedIds.insert(person.id)
        }

        // ── 2. LIKELY ATTENDEES ──
        var likely: [BriefPerson] = []

        for rel in relationships {
            guard likely.count < limit else { break }
            guard rel.profileId != myId else { continue }
            guard !claimedIds.contains(rel.profileId) else { continue }
            guard !mergedIds.contains(rel.profileId) else { continue }

            // Signal: attended similar events or connected to current attendees
            let hasEventOverlap = rel.eventContexts.contains(eventName)
                || rel.eventContexts.contains(where: { ctx in
                    mergedPeople.contains { a in
                        relById[a.id]?.eventContexts.contains(ctx) == true
                    }
                })
            let isConnectedToAttendee = connectedIds.contains(rel.profileId)
                && mergedPeople.contains(where: { connectedIds.contains($0.id) })

            guard hasEventOverlap || isConnectedToAttendee else { continue }

            let reason: String
            if rel.eventContexts.contains(eventName) {
                reason = "Attends this event"
            } else if isConnectedToAttendee {
                reason = "Connected to people here"
            } else {
                reason = "Attends similar events"
            }

            likely.append(BriefPerson(
                id: rel.profileId, name: rel.name,
                avatarUrl: rel.avatarUrl, descriptor: reason
            ))
            claimedIds.insert(rel.profileId)
        }

        // ── 3. SUGGESTED CONNECTIONS ──
        var suggested: [BriefConnection] = []
        var usedReasons = Set<String>()

        // Score all visible people, pick top candidates with mutual value
        var scoredForSuggestion: [(MergedAttendee, Double, RelationshipMemory?)] = []
        for person in mergedPeople {
            // Skip people in active interaction (3+ min)
            if let enc = encounters[person.id], enc.totalSeconds >= 180 { continue }

            let rel = relById[person.id]
            let isBLE = person.source == .ble || person.source == .bleAndBackend

            let signals: InteractionScorer.Signals
            if let rel {
                signals = InteractionScorer.signals(
                    for: rel, encounter: encounters[person.id],
                    bleDetected: isBLE, heartbeatLive: person.source == .backend || person.source == .bleAndBackend,
                    myInterests: myInterests
                )
            } else {
                signals = InteractionScorer.Signals(
                    isBLEDetected: isBLE,
                    isHeartbeatLive: person.source == .backend || person.source == .bleAndBackend,
                    encounterSeconds: encounters[person.id]?.totalSeconds ?? 0,
                    lastSeenAt: encounters[person.id]?.lastSeen,
                    isConnected: connectedIds.contains(person.id),
                    sharedInterestCount: Set((person.interests ?? []).map { $0.lowercased() }).intersection(myInterests).count
                )
            }

            let score = InteractionScorer.score(signals)
            guard score > 0 else { continue }
            scoredForSuggestion.append((person, score, rel))
        }

        scoredForSuggestion.sort { $0.1 > $1.1 }

        for (person, _, rel) in scoredForSuggestion {
            guard suggested.count < limit else { break }
            guard !claimedIds.contains(person.id) else { continue }

            let mutual = buildMutualValueFromMerged(
                person: person, rel: rel,
                myInterests: myInterests, mySkills: mySkills
            )
            guard let mutual else { continue }

            // Avoid repeating the same reasoning across people
            let reasonKey = "\(mutual.whyThey)|\(mutual.whyYou)"
            guard !usedReasons.contains(reasonKey) else { continue }
            usedReasons.insert(reasonKey)

            suggested.append(BriefConnection(
                id: person.id, name: person.name,
                avatarUrl: person.avatarUrl,
                whyTheyMatter: mutual.whyThey,
                whyYouMatter: mutual.whyYou
            ))
        }

        // ── 4. TALKING POINTS ──
        var points: [String] = []

        // Person-specific points from start-here targets first, then suggested
        let pointSources: [any Identifiable] = Array(startHere) + Array(suggested)
        for source in pointSources.prefix(2) {
            let sourceId = (source as? ArrivalTarget)?.id ?? (source as? BriefConnection)?.id
            let sourceName = (source as? ArrivalTarget)?.name ?? (source as? BriefConnection)?.name
            guard let id = sourceId, let name = sourceName else { continue }
            let firstName = name.components(separatedBy: " ").first ?? name
            let theirInterests = Set((mergedPeople.first(where: { $0.id == id })?.interests ?? []).map { $0.lowercased() })
            let shared = myInterests.intersection(theirInterests)
            if let topic = shared.first {
                points.append("Ask \(firstName) about \(topic)")
            }
        }

        // Event-context point
        if !eventName.isEmpty && points.count < 3 {
            let attendeesWithHistory = mergedPeople.filter { relById[$0.id] != nil }
            if let person = attendeesWithHistory.first {
                let name = person.name.components(separatedBy: " ").first ?? person.name
                points.append("Talk to \(name) about \(eventName)")
            }
        }

        let validPoints = Array(points.prefix(3))

        return EventBrief(
            startHere: startHere,
            hereNow: hereNow,
            likelyAttendees: likely,
            suggestedConnections: suggested,
            talkingPoints: validPoints
        )
    }

    // MARK: - Descriptor (strongest signal for a person)

    private static func buildDescriptor(
        attendee: EventAttendee,
        rel: RelationshipMemory?,
        myInterests: Set<String>,
        mySkills: Set<String>
    ) -> String {
        let theirInterests = Set((attendee.interests ?? []).map { $0.lowercased() })
        let theirSkills = Set((attendee.skills ?? []).map { $0.lowercased() })

        let sharedInterests = myInterests.intersection(theirInterests)
        if sharedInterests.count >= 2 {
            return sharedInterests.prefix(2).joined(separator: " + ")
        }
        if let interest = sharedInterests.first {
            let sharedSkills = mySkills.intersection(theirSkills)
            if let skill = sharedSkills.first, skill != interest {
                return "\(interest) + \(skill)"
            }
            return interest
        }

        let sharedSkills = mySkills.intersection(theirSkills)
        if let skill = sharedSkills.first { return skill }

        if let interest = theirInterests.first { return interest }
        if let skill = theirSkills.first { return skill }

        return ""
    }

    /// Descriptor from merged presence (may lack interests/skills for BLE-only people).
    private static func buildDescriptorFromMerged(
        person: MergedAttendee,
        rel: RelationshipMemory?,
        myInterests: Set<String>,
        mySkills: Set<String>
    ) -> String {
        let theirInterests = Set((person.interests ?? []).map { $0.lowercased() })
        let theirSkills = Set((person.skills ?? []).map { $0.lowercased() })

        let sharedInterests = myInterests.intersection(theirInterests)
        if sharedInterests.count >= 2 {
            return sharedInterests.prefix(2).joined(separator: " + ")
        }
        if let interest = sharedInterests.first { return interest }

        let sharedSkills = mySkills.intersection(theirSkills)
        if let skill = sharedSkills.first { return skill }

        // For BLE-only people, fall back to relationship data
        if let rel {
            if !rel.sharedInterests.isEmpty {
                return rel.sharedInterests.prefix(2).joined(separator: " + ")
            }
            if let event = rel.eventContexts.first {
                return "Also at \(event)"
            }
        }

        if let interest = theirInterests.first { return interest }
        return ""
    }

    /// Mutual value from merged presence.
    private static func buildMutualValueFromMerged(
        person: MergedAttendee,
        rel: RelationshipMemory?,
        myInterests: Set<String>,
        mySkills: Set<String>
    ) -> MutualValue? {
        if let rel {
            let traits = TraitReasoning.topTraits(for: rel, isHereNow: person.isHereNow)
            if !traits.isEmpty, let why = TraitReasoning.whyThisMattersLine(traits: traits) {
                return MutualValue(
                    whyThey: traits.joined(separator: " · "),
                    whyYou: why
                )
            }
        }

        let theirInterests = Set((person.interests ?? []).map { $0.lowercased() })
        let theirSkills = Set((person.skills ?? []).map { $0.lowercased() })
        let sharedInterests = myInterests.intersection(theirInterests)
        let theirUniqueSkills = theirSkills.subtracting(mySkills)
        let myUniqueSkills = mySkills.subtracting(theirSkills)

        if !sharedInterests.isEmpty && !theirUniqueSkills.isEmpty {
            let shared = sharedInterests.prefix(2).joined(separator: " + ")
            let theirEdge = theirUniqueSkills.first ?? ""
            return MutualValue(whyThey: "\(shared) — strong in \(theirEdge)", whyYou: "Overlapping focus, different angle")
        }
        if let theirEdge = theirUniqueSkills.first, let myEdge = myUniqueSkills.first {
            return MutualValue(whyThey: "Strong in \(theirEdge)", whyYou: "You bring \(myEdge)")
        }
        if sharedInterests.count >= 2 {
            let topics = sharedInterests.prefix(2).joined(separator: " + ")
            return MutualValue(whyThey: topics, whyYou: "Shared focus")
        }
        // Fall back to relationship data for BLE-only people
        if let rel, let event = rel.eventContexts.first {
            let overlap = rel.sharedInterests.first ?? ""
            return MutualValue(whyThey: "Also at \(event)", whyYou: overlap.isEmpty ? "You were both there" : overlap)
        }
        if let topic = sharedInterests.first {
            return MutualValue(whyThey: topic, whyYou: "Common ground")
        }
        // BLE-only with relationship history
        if let rel, !rel.sharedInterests.isEmpty {
            return MutualValue(whyThey: rel.sharedInterests.prefix(2).joined(separator: " + "), whyYou: "Shared interests")
        }
        return nil
    }

    // MARK: - Mutual Value (two-line reasoning)

    private struct MutualValue {
        let whyThey: String
        let whyYou: String
    }

    private static func buildMutualValue(
        attendee: EventAttendee,
        rel: RelationshipMemory?,
        myInterests: Set<String>,
        mySkills: Set<String>
    ) -> MutualValue? {
        let theirInterests = Set((attendee.interests ?? []).map { $0.lowercased() })
        let theirSkills = Set((attendee.skills ?? []).map { $0.lowercased() })
        let sharedInterests = myInterests.intersection(theirInterests)
        let sharedSkills = mySkills.intersection(theirSkills)
        let theirUniqueSkills = theirSkills.subtracting(mySkills)
        let myUniqueSkills = mySkills.subtracting(theirSkills)

        // Pattern 1: Shared domain + complementary skills
        if !sharedInterests.isEmpty && !theirUniqueSkills.isEmpty {
            let shared = sharedInterests.prefix(2).joined(separator: " + ")
            let theirEdge = theirUniqueSkills.first ?? ""
            return MutualValue(
                whyThey: "\(shared) — strong in \(theirEdge)",
                whyYou: "Overlapping focus, different angle"
            )
        }

        // Pattern 2: Complementary skills
        if let theirEdge = theirUniqueSkills.first, let myEdge = myUniqueSkills.first {
            return MutualValue(
                whyThey: "Strong in \(theirEdge)",
                whyYou: "You bring \(myEdge)"
            )
        }

        // Pattern 3: Shared interests only
        if sharedInterests.count >= 2 {
            let topics = sharedInterests.prefix(2).joined(separator: " + ")
            return MutualValue(
                whyThey: topics,
                whyYou: "Shared focus"
            )
        }

        // Pattern 4: Prior event overlap
        if let rel, let event = rel.eventContexts.first {
            let overlap = sharedInterests.first ?? sharedSkills.first ?? ""
            let whyYou = overlap.isEmpty ? "You were both there" : overlap
            return MutualValue(
                whyThey: "Also at \(event)",
                whyYou: whyYou
            )
        }

        // Pattern 5: Single shared interest
        if let topic = sharedInterests.first {
            return MutualValue(
                whyThey: topic,
                whyYou: "Common ground"
            )
        }

        // No meaningful mutual value — return nil (section won't render)
        return nil
    }
}

// MARK: - Arrival Target Builder
//
// Produces 1–2 prioritized "Start Here" targets from existing data.
// Uses a strict priority cascade with a guaranteed presence-based fallback.
// NEVER returns empty when attendees exist.

@MainActor
enum ArrivalTargetBuilder {

    /// Builds up to `limit` targets (max 2). Guaranteed non-empty when attendees exist.
    static func build(limit: Int) -> [ArrivalTarget] {
        guard limit > 0 else { return [] }
        guard let myId = AuthService.shared.currentUser?.id else { return [] }

        let mergedPeople = MergedPresenceBuilder.build(myId: myId)
        let encounters = EncounterService.shared.activeEncounters
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myInterests = Set((AuthService.shared.currentUser?.interests ?? []).map { $0.lowercased() })

        let relById = Dictionary(uniqueKeysWithValues: relationships.map { ($0.profileId, $0) })

        guard !mergedPeople.isEmpty else {
            #if DEBUG
            print("[ArrivalTarget] no visible people (backend=\(EventAttendeesService.shared.attendees.count) merged=0) — returning empty")
            #endif
            return []
        }

        #if DEBUG
        print("[ArrivalTarget] evaluating \(mergedPeople.count) merged people")
        #endif

        struct Candidate {
            let id: UUID
            let name: String
            let avatarUrl: String?
            let reason: String
            let priority: Int
            let score: Double
        }

        var candidates: [Candidate] = []

        for person in mergedPeople {
            let rel = relById[person.id]
            let encounter = encounters[person.id]
            let isConnected = connectedIds.contains(person.id)
            let theirInterests = Set((person.interests ?? []).map { $0.lowercased() })
            // Also check relationship shared interests for BLE-only people
            let effectiveSharedInterests = myInterests.intersection(theirInterests).union(
                Set((rel?.sharedInterests ?? []).map { $0.lowercased() }).intersection(myInterests)
            )

            // Score for tiebreaking
            let isBLE = person.source == .ble || person.source == .bleAndBackend
            let signals: InteractionScorer.Signals
            if let rel {
                signals = InteractionScorer.signals(
                    for: rel, encounter: encounter,
                    bleDetected: isBLE, heartbeatLive: person.source == .backend || person.source == .bleAndBackend,
                    myInterests: myInterests
                )
            } else {
                signals = InteractionScorer.Signals(
                    isBLEDetected: isBLE,
                    isHeartbeatLive: person.source == .backend || person.source == .bleAndBackend,
                    encounterSeconds: encounter?.totalSeconds ?? 0,
                    lastSeenAt: encounter?.lastSeen,
                    isConnected: isConnected,
                    sharedInterestCount: effectiveSharedInterests.count
                )
            }
            let score = InteractionScorer.score(signals)

            // ── Priority 1: Strong re-engagement ──
            if let rel, rel.totalOverlapSeconds >= 120 || rel.encounterCount >= 2 {
                let mins = rel.totalOverlapSeconds / 60
                let reason = mins >= 2
                    ? "You've spent \(mins) min together — strong connection"
                    : "You've crossed paths \(rel.encounterCount)× — worth reconnecting"
                candidates.append(Candidate(
                    id: person.id, name: person.name, avatarUrl: person.avatarUrl,
                    reason: reason, priority: 1, score: score
                ))
                continue
            }

            // ── Priority 2: Network leverage ──
            if isConnected || (rel?.connectionStatus == .accepted) {
                candidates.append(Candidate(
                    id: person.id, name: person.name, avatarUrl: person.avatarUrl,
                    reason: "Connected — easy conversation starter",
                    priority: 2, score: score
                ))
                continue
            }

            // ── Priority 3: Shared interest / skill ──
            if !effectiveSharedInterests.isEmpty {
                let topics = effectiveSharedInterests.prefix(2).joined(separator: " + ")
                candidates.append(Candidate(
                    id: person.id, name: person.name, avatarUrl: person.avatarUrl,
                    reason: "Shared interest in \(topics)",
                    priority: 3, score: score
                ))
                continue
            }

            // ── Priority 4: Presence-only fallback ──
            candidates.append(Candidate(
                id: person.id, name: person.name, avatarUrl: person.avatarUrl,
                reason: "Also here now — good opportunity to connect",
                priority: 4, score: score
            ))
        }

        // Sort: best priority first, then highest score within same priority
        candidates.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.score > b.score
        }

        let selected = Array(candidates.prefix(limit))

        #if DEBUG
        print("[ArrivalTarget] evaluated \(candidates.count) candidates from \(mergedPeople.count) merged people")
        for t in selected {
            let fallbackTag = t.priority == 4 ? " (FALLBACK)" : ""
            print("[ArrivalTarget] → \(t.name) [P\(t.priority)] \(t.reason)\(fallbackTag)")
        }
        if selected.isEmpty {
            print("[ArrivalTarget] ⚠️ no targets produced despite \(mergedPeople.count) visible people")
        }
        #endif

        return selected.map { c in
            ArrivalTarget(id: c.id, name: c.name, avatarUrl: c.avatarUrl, reason: c.reason)
        }
    }
}
