import Foundation
import Combine
import Supabase

// MARK: - Dynamic Profile Signals (for Home consumption)

/// Lightweight signal output that Home can use for "why" explanations.
/// Derived from existing data, not stored anywhere.
struct DynamicProfileSignals {
    /// User's top recent themes (e.g., ["health AI", "design"])
    let topThemes: [String]
    /// Most recent/active event name, if any
    let recentEventName: String?
    /// Whether user has recent follow-up behavior (messages after encounters)
    let hasFollowUpMomentum: Bool
    /// Raw recent shared interests from encounters (for overlap matching)
    let recentSharedInterests: Set<String>

    init(
        topThemes: [String] = [],
        recentEventName: String? = nil,
        hasFollowUpMomentum: Bool = false,
        recentSharedInterests: Set<String> = []
    ) {
        self.topThemes = topThemes
        self.recentEventName = recentEventName
        self.hasFollowUpMomentum = hasFollowUpMomentum
        self.recentSharedInterests = recentSharedInterests
    }
}

// MARK: - Public Profile Summary (for viewing other users)

/// Lightweight public-safe profile output for another user.
/// Derived from the viewer's own feed items involving the target user.
struct PublicProfileSummary {
    let latelyLines: [String]
    let emergingStrengthsParagraph: String?
    let earnedTraits: [EarnedTrait]
}

// MARK: - Earned Trait

/// A durable, behavior-backed identity trait earned through repeated activity.
/// Higher confidence threshold than Emerging Strengths.
struct EarnedTrait: Identifiable, Equatable {
    let id: String          // trait key: "follows-through", "consistently-active", "theme-driven"
    let publicText: String  // public-facing label
    let evidenceCount: Int  // number of qualifying evidence points
}

/// Generates "Lately" lines for the Profile tab.
/// Lightweight, client-side, derived from existing data sources.
/// Returns 0–3 short phrases reflecting recent activity patterns.
///
/// No Supabase schema changes. No new tables. No heavy AI.
@MainActor
final class DynamicProfileService: ObservableObject {

    static let shared = DynamicProfileService()

    @Published private(set) var latelyLines: [String] = []
    @Published private(set) var emergingStrengthsParagraph: String?
    @Published private(set) var earnedTraits: [EarnedTrait] = []
    @Published private(set) var isLoading = false

    /// Lightweight signals for Home to consume. Derived, not stored.
    @Published private(set) var currentSignals = DynamicProfileSignals()

    private let supabase = AppEnvironment.shared.supabaseClient
    private var lastGenerated: Date?

    private init() {}

    // MARK: - Time Weighting

    private enum Weight {
        static func forAge(_ age: TimeInterval) -> Double {
            let days = age / 86400
            if days <= 7  { return 1.0 }
            if days <= 14 { return 0.7 }
            if days <= 30 { return 0.4 }
            return 0
        }

        static let thirtyDays: TimeInterval = 30 * 86400
    }

    // MARK: - Public API

    /// Generates Lately lines from recent activity. Safe to call on appear.
    func refresh() {
        // Don't regenerate more than once per 5 minutes
        if let last = lastGenerated, Date().timeIntervalSince(last) < 300 {
            return
        }

        guard !isLoading else { return }
        isLoading = true

        Task {
            let lines = await generateLines()
            latelyLines = lines
            currentSignals = await buildSignals()
            emergingStrengthsParagraph = await generateEmergingStrengthsParagraph()
            earnedTraits = await generateEarnedTraits()
            lastGenerated = Date()
            isLoading = false

            #if DEBUG
            print("[Lately] Generated \(lines.count) lines: \(lines)")
            print("[Lately] Signals: themes=\(currentSignals.topThemes) event=\(currentSignals.recentEventName ?? "none") momentum=\(currentSignals.hasFollowUpMomentum) sharedInterests=\(currentSignals.recentSharedInterests.count)")
            print("[EmergingStrengths] Paragraph: \(emergingStrengthsParagraph ?? "nil")")
            print("[EarnedTraits] \(earnedTraits.map { $0.publicText })")
            #endif
        }
    }

    // MARK: - Public Profile Generation (for other users)

    /// Generates a public-safe profile summary for another user,
    /// derived from the current viewer's feed items involving that user.
    /// Returns nil-safe output — empty lines and nil paragraph are valid.
    func generatePublicProfile(for targetId: UUID, targetUser: User?) async -> PublicProfileSummary {
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        // Filter to feed items involving the target user
        let targetItems = feedItems.filter { item in
            item.actorProfileId == targetId &&
            (item.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }

        guard !targetItems.isEmpty else {
            return PublicProfileSummary(latelyLines: [], emergingStrengthsParagraph: nil, earnedTraits: [])
        }

        // ── Lately lines ──

        var lines: [String] = []

        // Event activity
        var eventNames: [String: Double] = [:]
        for item in targetItems {
            guard let eventName = item.metadata?.eventName, !eventName.isEmpty else { continue }
            guard let date = item.createdAt else { continue }
            eventNames[eventName, default: 0] += Weight.forAge(now.timeIntervalSince(date))
        }
        let topEvent = eventNames.max(by: { $0.value < $1.value })

        // Topic from user profile interests/skills + event themes
        var topicScores: [String: Double] = [:]
        for (eventName, weight) in eventNames {
            for theme in extractTopicWords(from: eventName) {
                topicScores[theme, default: 0] += weight
            }
        }
        for interest in targetUser?.interests ?? [] {
            let raw = interest.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw), raw.count >= 2 else { continue }
            topicScores[raw, default: 0] += 0.3
        }
        for skill in targetUser?.skills ?? [] {
            let raw = skill.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw), raw.count >= 2 else { continue }
            topicScores[raw, default: 0] += 0.2
        }
        for key in topicScores.keys where Self.vagueWords.contains(key) {
            topicScores[key] = (topicScores[key] ?? 0) * 0.3
        }

        let topTopics = topicScores.sorted { $0.value > $1.value }
            .prefix(2)
            .filter { $0.value >= 0.3 }
            .map { $0.key }

        // Use target user's ID for template variation (so different users get different phrasing)
        let variant = (targetId.uuidString.hashValue &+ (Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 0)) & 0x7FFFFFFF

        if topTopics.count >= 2 {
            let templates: [(String, String) -> String] = [
                { "Exploring \($0) and \($1)" },
                { "Focused on \($0) and \($1)" },
            ]
            lines.append(templates[variant % templates.count](topTopics[0], topTopics[1]))
        } else if let topic = topTopics.first {
            let templates: [(String) -> String] = [
                { "Exploring \($0)" },
                { "Focused on \($0)" },
            ]
            lines.append(templates[variant % templates.count](topic))
        }

        if let event = topEvent, event.value >= 0.4 {
            let templates: [(String) -> String] = [
                { "Active at \($0)" },
                { "Showing up at \($0)" },
            ]
            lines.append(templates[variant % templates.count](event.key))
        }

        // ── Emerging Strengths paragraph ──

        let messageItems = targetItems.filter { $0.feedType == .message }
        let connectionItems = targetItems.filter { $0.feedType == .connection }
        let messageCount = messageItems.count
        let distinctEventCount = eventNames.count

        var traits: [String] = []

        // Follow-through
        if messageCount >= 2 && !connectionItems.isEmpty {
            traits.append("They often follow up after events.")
        }

        // Consistency
        if distinctEventCount >= 3 {
            if let dom = topEvent, dom.value >= 1.0 {
                traits.append("They regularly attend \(dom.key) events.")
            } else {
                traits.append("They consistently show up in community gatherings.")
            }
        }

        // Connector behavior (shared interests across multiple encounters)
        var themeConnections: [String: Int] = [:]
        for item in targetItems {
            guard item.feedType == .encounter || item.feedType == .connection else { continue }
            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard key.count >= 2, !Self.vagueWords.contains(key) else { continue }
                    themeConnections[key, default: 0] += 1
                }
            }
        }
        let topConnectorTheme = themeConnections.filter { $0.value >= 2 }.max(by: { $0.value < $1.value })
        if let theme = topConnectorTheme {
            traits.append("They connect others around \(theme.key).")
        }

        // Thematic engagement
        let topTheme = topicScores.filter { $0.value >= 1.0 && !Self.vagueWords.contains($0.key) }
            .max(by: { $0.value < $1.value })
        if let theme = topTheme, traits.count < 2 {
            traits.append("They are active in conversations around \(theme.key).")
        }

        let paragraph: String? = traits.isEmpty ? nil : traits.prefix(2).joined(separator: " ")

        // Earned traits for public profile (same evidence rules, applied to target items)
        let publicEarned = evaluateEarnedTraits(
            feedItems: targetItems,
            targetUser: targetUser,
            topicScores: topicScores
        )

        return PublicProfileSummary(
            latelyLines: Array(lines.prefix(3)),
            emergingStrengthsParagraph: paragraph,
            earnedTraits: publicEarned
        )
    }

    // MARK: - Generation Pipeline

    private func generateLines() async -> [String] {
        guard let myId = AuthService.shared.currentUser?.id else { return [] }
        let user = AuthService.shared.currentUser

        // Step 1: Gather signals
        let eventSignals = await gatherEventSignals(myId: myId)
        let connectionSignals = await gatherConnectionSignals(myId: myId)
        let encounterSignals = gatherEncounterSignals()
        let messageSignals = gatherMessageSignals()

        // Step 2: Generate candidates in 3 categories
        var candidates: [(line: String, score: Double, category: Category)] = []

        // Category 1: Topic / Focus
        if let topicLine = generateTopicLine(
            user: user,
            eventSignals: eventSignals,
            connectionSignals: connectionSignals
        ) {
            candidates.append(topicLine)
        }

        // Category 2: People / Network Pattern
        if let peopleLine = generatePeopleLine(
            connectionSignals: connectionSignals,
            encounterSignals: encounterSignals
        ) {
            candidates.append(peopleLine)
        }

        // Category 3: Activity / Momentum
        if let activityLine = generateActivityLine(
            eventSignals: eventSignals,
            messageSignals: messageSignals,
            encounterSignals: encounterSignals
        ) {
            candidates.append(activityLine)
        }

        // Step 3: Selection with user-specific priority
        //
        // Rule: topic and people phrases are user-specific (derived from personal
        // interests, skills, shared_interests). Activity/momentum phrases are
        // shared-event context (same event name across all attendees).
        //
        // User-specific lines MUST appear before shared-event lines.
        // A shared-event phrase may appear as a supporting line, never the sole identity line.

        let threshold: Double = 0.35

        let topicCandidate = candidates.first { $0.category == .topic && $0.score >= threshold }
        let peopleCandidate = candidates.first { $0.category == .people && $0.score >= threshold }
        let activityCandidate = candidates.first { $0.category == .activity && $0.score >= threshold }

        #if DEBUG
        print("[Lately] ── Candidate selection ──")
        print("[Lately]   topic:    \(topicCandidate.map { "\($0.line) (score=\(String(format: "%.2f", $0.score)))" } ?? "none")")
        print("[Lately]   people:   \(peopleCandidate.map { "\($0.line) (score=\(String(format: "%.2f", $0.score)))" } ?? "none")")
        print("[Lately]   momentum: \(activityCandidate.map { "\($0.line) (score=\(String(format: "%.2f", $0.score)))" } ?? "none")")
        #endif

        // Assemble: user-specific first, shared-event second
        var result: [String] = []
        let hasUserSpecific = topicCandidate != nil || peopleCandidate != nil

        // 1. Always include user-specific lines first (topic, then people)
        if let topic = topicCandidate {
            result.append(topic.line)
        }
        if let people = peopleCandidate, result.count < 3 {
            result.append(people.line)
        }

        // 2. Activity/momentum line: only as secondary, never the sole line
        //    when user-specific candidates exist
        if let activity = activityCandidate, result.count < 3 {
            if !hasUserSpecific {
                // No user-specific lines survived → show one shared-event line
                result.append(activity.line)
                #if DEBUG
                print("[Lately]   ⚠️ Shared event phrase is sole line (no user-specific candidates)")
                #endif
            } else {
                // User-specific lines exist → shared event is supporting context
                result.append(activity.line)
                #if DEBUG
                print("[Lately]   ✅ Shared event phrase added as supporting line")
                #endif
            }
        }

        // 3. If still empty and we have a topic or people below threshold,
        //    try to rescue using user interests/skills as differentiation anchor
        if result.isEmpty {
            let user = AuthService.shared.currentUser
            let interests = user?.interests ?? []
            let skills = user?.skills ?? []
            let anchors = (interests + skills)
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !Self.vagueWords.contains($0) && $0.count >= 2 }

            if let anchor = anchors.first {
                let templates: [(String) -> String] = [
                    { "Lately focused on \($0)" },
                    { "Spending time around \($0)" },
                    { "Getting deeper into \($0)" },
                ]
                let t = templates[templateVariant % templates.count]
                result.append(t(anchor))
                #if DEBUG
                print("[Lately]   🔄 Rescued with interest anchor: \(anchor)")
                #endif
            }
        }

        #if DEBUG
        print("[Lately]   final: \(result)")
        #endif

        return result
    }

    private enum Category: Hashable {
        case topic
        case people
        case activity
    }

    // MARK: - Signal Gathering

    private struct EventSignal {
        let eventName: String
        let date: Date
        let weight: Double
    }

    private struct ConnectionSignal {
        let name: String
        let date: Date
        let weight: Double
    }

    private struct EncounterSignal {
        let name: String
        let overlapSeconds: Int
        let date: Date
        let weight: Double
    }

    private struct MessageSignal {
        let date: Date
        let weight: Double
    }

    private func gatherEventSignals(myId: UUID) async -> [EventSignal] {
        // Use feed items with event context (already loaded)
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        var signals: [EventSignal] = []
        var seenEvents: Set<String> = []

        for item in feedItems {
            guard let eventName = item.metadata?.eventName, !eventName.isEmpty else { continue }
            guard let date = item.createdAt else { continue }
            let age = now.timeIntervalSince(date)
            guard age < Weight.thirtyDays else { continue }

            let key = eventName.lowercased()
            guard !seenEvents.contains(key) else { continue }
            seenEvents.insert(key)

            signals.append(EventSignal(
                eventName: eventName,
                date: date,
                weight: Weight.forAge(age)
            ))
        }

        // Also check current event
        if let currentEvent = EventJoinService.shared.currentEventName {
            let key = currentEvent.lowercased()
            if !seenEvents.contains(key) {
                signals.append(EventSignal(
                    eventName: currentEvent,
                    date: now,
                    weight: 1.0
                ))
            }
        }

        return signals
    }

    private func gatherConnectionSignals(myId: UUID) async -> [ConnectionSignal] {
        do {
            let connections = try await ConnectionService.shared.fetchConnections()
            let now = Date()

            return connections.compactMap { conn -> ConnectionSignal? in
                guard let date = conn.createdAt else { return nil }
                let age = now.timeIntervalSince(date)
                guard age < Weight.thirtyDays else { return nil }

                let other = conn.otherUser(for: myId)
                return ConnectionSignal(
                    name: other.name,
                    date: date,
                    weight: Weight.forAge(age)
                )
            }
        } catch {
            #if DEBUG
            print("[Lately] Failed to fetch connections: \(error)")
            #endif
            return []
        }
    }

    private func gatherEncounterSignals() -> [EncounterSignal] {
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        return feedItems.compactMap { item -> EncounterSignal? in
            guard item.feedType == .encounter else { return nil }
            guard let date = item.createdAt else { return nil }
            let age = now.timeIntervalSince(date)
            guard age < Weight.thirtyDays else { return nil }

            return EncounterSignal(
                name: item.metadata?.actorName ?? "",
                overlapSeconds: item.metadata?.overlapSeconds ?? 0,
                date: date,
                weight: Weight.forAge(age)
            )
        }
    }

    private func gatherMessageSignals() -> [MessageSignal] {
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        return feedItems.compactMap { item -> MessageSignal? in
            guard item.feedType == .message else { return nil }
            guard let date = item.createdAt else { return nil }
            let age = now.timeIntervalSince(date)
            guard age < Weight.thirtyDays else { return nil }

            return MessageSignal(date: date, weight: Weight.forAge(age))
        }
    }

    // MARK: - Phrase Generation

    // ── Vague words to demote in topic/theme selection ──
    private static let vagueWords: Set<String> = [
        "technology", "tech", "innovation", "community", "digital",
        "general", "social", "global", "future", "new", "open",
        "people", "world", "things", "stuff", "ideas", "space",
        "startups", "tech events"  // over-collapsed buckets
    ]

    // ── Template variation: rotate phrasing based on user ID hash ──
    private var templateVariant: Int {
        let id = AuthService.shared.currentUser?.id.uuidString ?? ""
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return (id.hashValue &+ dayOfYear) & 0x7FFFFFFF
    }

    /// Category 1: Topic / Focus
    /// Prefers user-specific themes over collapsed buckets.
    /// Only uses a mapped theme if it has 2+ distinct signal sources.
    /// Falls back to raw user interests (already human-readable).
    private func generateTopicLine(
        user: User?,
        eventSignals: [EventSignal],
        connectionSignals: [ConnectionSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let interests = user?.interests ?? []
        let skills = user?.skills ?? []

        // Track signal source count per theme for differentiation
        var themeSources: [String: Set<String>] = [:]  // theme → set of source labels
        var topicScores: [String: Double] = [:]

        // Event-derived themes
        for signal in eventSignals {
            let themes = extractTopicWords(from: signal.eventName)
            for theme in themes {
                topicScores[theme, default: 0] += signal.weight
                themeSources[theme, default: []].insert("event:\(signal.eventName)")
            }
        }

        // User interests — use raw text (already readable), not collapsed themes
        for interest in interests {
            let raw = interest.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw) else { continue }
            topicScores[raw, default: 0] += 0.3
            themeSources[raw, default: []].insert("interest")
        }
        for skill in skills {
            let raw = skill.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw) else { continue }
            topicScores[raw, default: 0] += 0.2
            themeSources[raw, default: []].insert("skill")
        }

        // Demote vague/over-collapsed themes
        for key in topicScores.keys where Self.vagueWords.contains(key) {
            topicScores[key] = (topicScores[key] ?? 0) * 0.3
        }

        // Differentiation: boost themes with 2+ distinct sources
        for (theme, sources) in themeSources where sources.count >= 2 {
            topicScores[theme] = (topicScores[theme] ?? 0) * 1.3
        }

        let sorted = topicScores.sorted { $0.value > $1.value }
        guard let first = sorted.first, first.value >= 0.4 else { return nil }

        let strong = sorted.filter { $0.value >= first.value * 0.5 }.prefix(2)
        let topThemes = strong.map { $0.key }
        let totalScore = strong.reduce(0.0) { $0 + $1.value }

        // Template variation
        let templates2: [(String, String) -> String] = [
            { "Spending time around \($0) and \($1)" },
            { "Lately focused on \($0) and \($1)" },
            { "Getting deeper into \($0) and \($1)" },
        ]
        let templates1: [(String) -> String] = [
            { "Getting deeper into \($0)" },
            { "Lately focused on \($0)" },
            { "Spending time around \($0)" },
        ]

        let line: String
        if topThemes.count >= 2 {
            let t = templates2[templateVariant % templates2.count]
            line = t(topThemes[0], topThemes[1])
        } else {
            let t = templates1[templateVariant % templates1.count]
            line = t(topThemes[0])
        }

        return (line, min(totalScore / 2.0, 1.0), .topic)
    }

    /// Category 2: People / Network
    /// Uses raw shared_interests from encounters (user-specific, not collapsed).
    /// Prefers concrete interest labels over generic role buckets.
    private func generatePeopleLine(
        connectionSignals: [ConnectionSignal],
        encounterSignals: [EncounterSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let totalPeople = connectionSignals.count + encounterSignals.count
        let weightedScore = connectionSignals.reduce(0.0) { $0 + $1.weight }
            + encounterSignals.reduce(0.0) { $0 + $1.weight }

        guard totalPeople >= 2 else { return nil }

        // Collect raw shared interests — keep user-specific labels, don't collapse
        let feedItems = FeedService.shared.feedItems
        var roleCounts: [String: Double] = [:]
        for item in feedItems {
            guard item.feedType == .encounter || item.feedType == .connection else { continue }
            guard let date = item.createdAt else { continue }
            let w = Weight.forAge(Date().timeIntervalSince(date))
            guard w > 0 else { continue }

            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let raw = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(raw), raw.count >= 2 else { continue }
                    roleCounts[raw, default: 0] += w
                }
            }
        }

        let topRoles = roleCounts.sorted { $0.value > $1.value }.prefix(2).map { $0.key }

        let templates2: [(String, String) -> String] = [
            { "Connecting with people in \($0) and \($1)" },
            { "Meeting people into \($0) and \($1)" },
            { "Spending time with people around \($0) and \($1)" },
        ]
        let templates1: [(String) -> String] = [
            { "Connecting with others around \($0)" },
            { "Meeting people into \($0)" },
        ]

        let line: String
        if topRoles.count >= 2 {
            let t = templates2[templateVariant % templates2.count]
            line = t(topRoles[0], topRoles[1])
        } else if let role = topRoles.first {
            let t = templates1[templateVariant % templates1.count]
            line = t(role)
        } else {
            return nil  // no role data → omit entirely, don't fill with generic
        }

        return (line, min(weightedScore / 3.0, 1.0), .people)
    }

    /// Category 3: Activity / Momentum
    /// Always anchors to real event names. Never outputs generic "community" language.
    private func generateActivityLine(
        eventSignals: [EventSignal],
        messageSignals: [MessageSignal],
        encounterSignals: [EncounterSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let eventCount = eventSignals.count
        let messageCount = messageSignals.count
        let encounterCount = encounterSignals.count

        // Always prefer the strongest named event
        let topEvent = eventSignals.sorted { $0.weight > $1.weight }.first

        // Multiple events → anchor to the top one
        if eventCount >= 2, let event = topEvent {
            let score = eventSignals.reduce(0.0) { $0 + $1.weight } / 2.0
            let templates: [(String) -> String] = [
                { "Active at \($0) events" },
                { "Showing up at \($0)" },
                { "Spending time at \($0) events" },
            ]
            let t = templates[templateVariant % templates.count]
            return (t(event.eventName), min(score, 1.0), .activity)
        }

        // Follow-up behavior anchored to event if possible
        if messageCount >= 2 && encounterCount >= 1 {
            let score = messageSignals.reduce(0.0) { $0 + $1.weight } / 2.0
            if let event = topEvent {
                return ("Following up after \(event.eventName)", min(score, 1.0), .activity)
            }
            return ("Following up after recent events", min(score, 1.0), .activity)
        }

        // Single event with supporting activity
        if let event = topEvent {
            if messageCount >= 1 || encounterCount >= 1 {
                let totalWeight = event.weight + messageSignals.reduce(0.0) { $0 + $1.weight }
                return ("Showing up at \(event.eventName)", min(totalWeight / 2.0, 1.0), .activity)
            }
            if event.weight >= 0.7 {
                return ("Active at \(event.eventName)", event.weight * 0.6, .activity)
            }
        }

        // No event at all → omit entirely (don't fill with generic)
        return nil
    }

    // MARK: - Signal Builder (for Home)

    /// Builds lightweight signals from the same data sources used for Lately lines.
    /// Called alongside generateLines() so signals are always fresh.
    private func buildSignals() async -> DynamicProfileSignals {
        guard AuthService.shared.currentUser?.id != nil else {
            return DynamicProfileSignals()
        }
        let user = AuthService.shared.currentUser
        let interests = user?.interests ?? []
        let skills = user?.skills ?? []

        let feedItems = FeedService.shared.feedItems
        let now = Date()

        // Top themes: same logic as topic line but just extract the ranked list
        var topicScores: [String: Double] = [:]
        for item in feedItems {
            guard let eventName = item.metadata?.eventName, !eventName.isEmpty else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            let w = Weight.forAge(now.timeIntervalSince(date))
            for theme in extractTopicWords(from: eventName) {
                topicScores[theme, default: 0] += w
            }
        }
        for interest in interests {
            let raw = interest.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw) else { continue }
            topicScores[raw, default: 0] += 0.3
        }
        for skill in skills {
            let raw = skill.lowercased().trimmingCharacters(in: .whitespaces)
            guard !Self.vagueWords.contains(raw) else { continue }
            topicScores[raw, default: 0] += 0.2
        }
        for key in topicScores.keys where Self.vagueWords.contains(key) {
            topicScores[key] = (topicScores[key] ?? 0) * 0.3
        }
        let topThemes = topicScores.sorted { $0.value > $1.value }
            .prefix(3)
            .filter { $0.value >= 0.3 }
            .map { $0.key }

        // Recent event
        let recentEvent = EventJoinService.shared.currentEventName
            ?? feedItems
                .compactMap { item -> (String, Date)? in
                    guard let name = item.metadata?.eventName, let date = item.createdAt else { return nil }
                    return (name, date)
                }
                .sorted { $0.1 > $1.1 }
                .first?.0

        // Follow-up momentum: messages + encounters both present recently
        let hasMessages = feedItems.contains { $0.feedType == .message && ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false) }
        let hasEncounters = feedItems.contains { $0.feedType == .encounter && ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false) }
        let hasFollowUp = hasMessages && hasEncounters

        // Recent shared interests from encounters/connections
        var sharedInterests: Set<String> = []
        for item in feedItems {
            guard item.feedType == .encounter || item.feedType == .connection else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let raw = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    if raw.count >= 2 { sharedInterests.insert(raw) }
                }
            }
        }

        return DynamicProfileSignals(
            topThemes: topThemes,
            recentEventName: recentEvent,
            hasFollowUpMomentum: hasFollowUp,
            recentSharedInterests: sharedInterests
        )
    }

    // MARK: - Earned Traits

    /// Generates durable, behavior-backed earned traits for the current user.
    /// Higher confidence threshold than Emerging Strengths.
    /// Returns 0–3 traits max.
    func generateEarnedTraits() async -> [EarnedTrait] {
        let feedItems = FeedService.shared.feedItems
        let user = AuthService.shared.currentUser

        // Build topic scores for theme-driven trait
        var topicScores: [String: Double] = [:]
        let now = Date()
        for item in feedItems {
            guard let date = item.createdAt else { continue }
            let w = Weight.forAge(now.timeIntervalSince(date))
            guard w > 0 else { continue }
            if let eventName = item.metadata?.eventName {
                for theme in extractTopicWords(from: eventName) {
                    topicScores[theme, default: 0] += w
                }
            }
            if let shared = item.metadata?.sharedInterests {
                for interest in shared {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(key), key.count >= 2 else { continue }
                    topicScores[key, default: 0] += w
                }
            }
        }
        for interest in user?.interests ?? [] {
            let key = normalizeInterest(interest)
            if topicScores[key] != nil { topicScores[key]! += 0.3 }
        }
        for skill in user?.skills ?? [] {
            let key = normalizeInterest(skill)
            if topicScores[key] != nil { topicScores[key]! += 0.2 }
        }

        return evaluateEarnedTraits(
            feedItems: feedItems,
            targetUser: user,
            topicScores: topicScores
        )
    }

    /// Shared evaluation logic for earned traits. Used by both self-profile and public-profile paths.
    /// Applies strict thresholds: repetition, time consistency, context diversity.
    private func evaluateEarnedTraits(
        feedItems: [FeedItem],
        targetUser: User?,
        topicScores: [String: Double]
    ) -> [EarnedTrait] {
        let now = Date()
        var result: [EarnedTrait] = []

        // ── 1. Follows Through ──
        // Evidence: ≥3 follow-up messages after meeting people, across ≥2 unique people, across ≥2 event contexts
        let messageItems = feedItems.filter { $0.feedType == .message }
        let connectionItems = feedItems.filter { $0.feedType == .connection }

        // Find people the user both connected with AND messaged
        let connectedActorIds = Set(connectionItems.compactMap { $0.actorProfileId })
        let messagedActorIds = Set(messageItems.compactMap { $0.actorProfileId })
        let followedUpPeople = connectedActorIds.intersection(messagedActorIds)

        // Count total follow-up messages (messages to people we connected with)
        let followUpMessages = messageItems.filter { item in
            guard let actorId = item.actorProfileId else { return false }
            return followedUpPeople.contains(actorId)
        }

        // Event contexts for follow-up (from the connection items for followed-up people)
        let followUpEventContexts = Set(
            connectionItems
                .filter { item in
                    guard let actorId = item.actorProfileId else { return false }
                    return followedUpPeople.contains(actorId)
                }
                .compactMap { $0.eventId }
        )
        // Also count distinct days as context diversity proxy
        let followUpDays = Set(
            followUpMessages.compactMap { item -> String? in
                guard let date = item.createdAt else { return nil }
                let cal = Calendar.current
                return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
            }
        )
        let followUpContexts = max(followUpEventContexts.count, followUpDays.count)

        if followUpMessages.count >= 3 && followedUpPeople.count >= 2 && followUpContexts >= 2 {
            result.append(EarnedTrait(
                id: "follows-through",
                publicText: "Follows through after events",
                evidenceCount: followUpMessages.count
            ))
        }

        // ── 2. Consistently Active ──
        // Evidence: activity across ≥3 separate days OR ≥3 events, spanning time not one burst
        let allDates = feedItems.compactMap { $0.createdAt }
        let activeDays = Set(allDates.map { date -> String in
            let cal = Calendar.current
            return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
        })

        var eventNames: Set<String> = []
        for item in feedItems {
            if let name = item.metadata?.eventName, !name.isEmpty {
                eventNames.insert(name.lowercased())
            }
        }

        // Time span check: earliest to latest activity must span ≥3 days
        let sortedDates = allDates.sorted()
        let timeSpanDays: Int
        if let earliest = sortedDates.first, let latest = sortedDates.last {
            timeSpanDays = max(1, Int(latest.timeIntervalSince(earliest) / 86400))
        } else {
            timeSpanDays = 0
        }
        let spansTime = timeSpanDays >= 3

        let dayCount = activeDays.count
        let eventCount = eventNames.count

        if (dayCount >= 3 || eventCount >= 3) && spansTime {
            // Check if a specific event family dominates
            var eventNameCounts: [String: Int] = [:]
            for item in feedItems {
                if let name = item.metadata?.eventName, !name.isEmpty {
                    eventNameCounts[name, default: 0] += 1
                }
            }
            let dominant = eventNameCounts.max(by: { $0.value < $1.value })

            let text: String
            if let dom = dominant, dom.value >= 3, eventCount <= 2 {
                text = "Consistently active at \(dom.key) events"
            } else {
                text = "Consistently active in community spaces"
            }

            result.append(EarnedTrait(
                id: "consistently-active",
                publicText: text,
                evidenceCount: max(dayCount, eventCount)
            ))
        }

        // ── 3. Theme-Driven ──
        // Evidence: repeated theme signal across ≥2 contexts, supported by profile + behavioral data
        // Find themes with strong scores that appear in multiple contexts
        var themeContexts: [String: Set<String>] = [:]
        for item in feedItems {
            guard let date = item.createdAt else { continue }
            let w = Weight.forAge(now.timeIntervalSince(date))
            guard w > 0 else { continue }

            var itemThemes: [String] = []
            if let eventName = item.metadata?.eventName {
                itemThemes.append(contentsOf: extractTopicWords(from: eventName))
            }
            if let shared = item.metadata?.sharedInterests {
                for interest in shared {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(key), key.count >= 2 else { continue }
                    itemThemes.append(key)
                }
            }

            // Context = event ID or day (for context diversity)
            let context: String
            if let eventId = item.eventId {
                context = "event:\(eventId)"
            } else {
                let cal = Calendar.current
                context = "day:\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
            }

            for theme in itemThemes {
                themeContexts[theme, default: []].insert(context)
            }
        }

        // Boost themes that match user profile
        let userAnchors = Set(
            ((targetUser?.interests ?? []) + (targetUser?.skills ?? []))
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !Self.vagueWords.contains($0) }
        )

        // Find the best theme: ≥2 contexts, decent topic score, profile match preferred
        let qualifiedThemes = themeContexts
            .filter { $0.value.count >= 2 && !Self.vagueWords.contains($0.key) }
            .sorted { a, b in
                let scoreA = (topicScores[a.key] ?? 0) * (userAnchors.contains(a.key) ? 1.5 : 1.0)
                let scoreB = (topicScores[b.key] ?? 0) * (userAnchors.contains(b.key) ? 1.5 : 1.0)
                if scoreA != scoreB { return scoreA > scoreB }
                return a.value.count > b.value.count
            }

        if let best = qualifiedThemes.first,
           (topicScores[best.key] ?? 0) >= 1.0 {
            result.append(EarnedTrait(
                id: "theme-driven",
                publicText: "Active around \(best.key) conversations",
                evidenceCount: best.value.count
            ))
        }

        return Array(result.prefix(3))
    }

    /// Produces debug evidence for all 3 earned trait candidates.
    /// Reuses the same metric computation as evaluateEarnedTraits but captures
    /// actual vs required values for each threshold.
    func evaluateEarnedTraitEvidence(
        feedItems: [FeedItem],
        targetUser: User?,
        topicScores: [String: Double]
    ) -> [DebugProfileSummary.EarnedTraitEvidence] {
        typealias Evidence = DebugProfileSummary.EarnedTraitEvidence
        typealias Metric = Evidence.Metric
        let now = Date()
        var evidence: [Evidence] = []

        // ── 1. Follows Through ──
        let messageItems = feedItems.filter { $0.feedType == .message }
        let connectionItems = feedItems.filter { $0.feedType == .connection }
        let connectedActorIds = Set(connectionItems.compactMap { $0.actorProfileId })
        let messagedActorIds = Set(messageItems.compactMap { $0.actorProfileId })
        let followedUpPeople = connectedActorIds.intersection(messagedActorIds)
        let followUpMessages = messageItems.filter { item in
            guard let actorId = item.actorProfileId else { return false }
            return followedUpPeople.contains(actorId)
        }
        let followUpEventContexts = Set(
            connectionItems
                .filter { item in
                    guard let actorId = item.actorProfileId else { return false }
                    return followedUpPeople.contains(actorId)
                }
                .compactMap { $0.eventId }
        )
        let followUpDays = Set(
            followUpMessages.compactMap { item -> String? in
                guard let date = item.createdAt else { return nil }
                let cal = Calendar.current
                return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
            }
        )
        let followUpContexts = max(followUpEventContexts.count, followUpDays.count)
        let ftQualified = followUpMessages.count >= 3 && followedUpPeople.count >= 2 && followUpContexts >= 2

        evidence.append(Evidence(
            traitKey: "follows-through",
            traitName: "Follows Through",
            qualified: ftQualified,
            outputText: ftQualified ? "Follows through after events" : nil,
            metrics: [
                Metric(label: "Follow-up messages", actual: "\(followUpMessages.count)", required: "≥ 3", met: followUpMessages.count >= 3),
                Metric(label: "Unique people", actual: "\(followedUpPeople.count)", required: "≥ 2", met: followedUpPeople.count >= 2),
                Metric(label: "Contexts", actual: "\(followUpContexts)", required: "≥ 2", met: followUpContexts >= 2),
            ]
        ))

        // ── 2. Consistently Active ──
        let allDates = feedItems.compactMap { $0.createdAt }
        let activeDays = Set(allDates.map { date -> String in
            let cal = Calendar.current
            return "\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
        })
        var eventNames: Set<String> = []
        for item in feedItems {
            if let name = item.metadata?.eventName, !name.isEmpty {
                eventNames.insert(name.lowercased())
            }
        }
        let sortedDates = allDates.sorted()
        let timeSpanDays: Int
        if let earliest = sortedDates.first, let latest = sortedDates.last {
            timeSpanDays = max(1, Int(latest.timeIntervalSince(earliest) / 86400))
        } else {
            timeSpanDays = 0
        }
        let dayCount = activeDays.count
        let eventCount = eventNames.count
        let caQualified = (dayCount >= 3 || eventCount >= 3) && timeSpanDays >= 3

        var caText: String? = nil
        if caQualified {
            var eventNameCounts: [String: Int] = [:]
            for item in feedItems {
                if let name = item.metadata?.eventName, !name.isEmpty {
                    eventNameCounts[name, default: 0] += 1
                }
            }
            let dominant = eventNameCounts.max(by: { $0.value < $1.value })
            if let dom = dominant, dom.value >= 3, eventCount <= 2 {
                caText = "Consistently active at \(dom.key) events"
            } else {
                caText = "Consistently active in community spaces"
            }
        }

        evidence.append(Evidence(
            traitKey: "consistently-active",
            traitName: "Consistently Active",
            qualified: caQualified,
            outputText: caText,
            metrics: [
                Metric(label: "Active days", actual: "\(dayCount)", required: "≥ 3", met: dayCount >= 3),
                Metric(label: "Events", actual: "\(eventCount)", required: "≥ 3", met: eventCount >= 3),
                Metric(label: "Time span (days)", actual: "\(timeSpanDays)", required: "≥ 3", met: timeSpanDays >= 3),
            ]
        ))

        // ── 3. Theme-Driven ──
        var themeContexts: [String: Set<String>] = [:]
        for item in feedItems {
            guard let date = item.createdAt else { continue }
            let w = Weight.forAge(now.timeIntervalSince(date))
            guard w > 0 else { continue }
            var itemThemes: [String] = []
            if let eventName = item.metadata?.eventName {
                itemThemes.append(contentsOf: extractTopicWords(from: eventName))
            }
            if let shared = item.metadata?.sharedInterests {
                for interest in shared {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(key), key.count >= 2 else { continue }
                    itemThemes.append(key)
                }
            }
            let context: String
            if let eventId = item.eventId {
                context = "event:\(eventId)"
            } else {
                let cal = Calendar.current
                context = "day:\(cal.component(.year, from: date))-\(cal.component(.month, from: date))-\(cal.component(.day, from: date))"
            }
            for theme in itemThemes {
                themeContexts[theme, default: []].insert(context)
            }
        }
        let userAnchors = Set(
            ((targetUser?.interests ?? []) + (targetUser?.skills ?? []))
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !Self.vagueWords.contains($0) }
        )
        let qualifiedThemes = themeContexts
            .filter { $0.value.count >= 2 && !Self.vagueWords.contains($0.key) }
            .sorted { a, b in
                let scoreA = (topicScores[a.key] ?? 0) * (userAnchors.contains(a.key) ? 1.5 : 1.0)
                let scoreB = (topicScores[b.key] ?? 0) * (userAnchors.contains(b.key) ? 1.5 : 1.0)
                if scoreA != scoreB { return scoreA > scoreB }
                return a.value.count > b.value.count
            }
        let bestTheme = qualifiedThemes.first
        let bestThemeScore = bestTheme.flatMap { topicScores[$0.key] } ?? 0
        let bestThemeContextCount = bestTheme?.value.count ?? 0
        let bestThemeProfileMatch = bestTheme.map { userAnchors.contains($0.key) } ?? false
        let tdQualified = bestTheme != nil && bestThemeScore >= 1.0

        evidence.append(Evidence(
            traitKey: "theme-driven",
            traitName: "Theme-Driven",
            qualified: tdQualified,
            outputText: tdQualified ? "Active around \(bestTheme!.key) conversations" : nil,
            metrics: [
                Metric(label: "Theme", actual: bestTheme?.key ?? "(none)", required: "exists", met: bestTheme != nil),
                Metric(label: "Contexts", actual: "\(bestThemeContextCount)", required: "≥ 2", met: bestThemeContextCount >= 2),
                Metric(label: "Topic score", actual: String(format: "%.1f", bestThemeScore), required: "≥ 1.0", met: bestThemeScore >= 1.0),
                Metric(label: "Profile match", actual: bestThemeProfileMatch ? "yes" : "no", required: "preferred", met: bestThemeProfileMatch),
            ]
        ))

        return evidence
    }

    // MARK: - Emerging Strengths

    /// Confidence tier for behavioral traits.
    /// Each signal family produces exactly one tier — the highest earned.
    private enum ConfidenceTier: Int, Comparable {
        case low = 1      // weak but meaningful anchor
        case medium = 2   // repeated signal or moderate support
        case high = 3     // multi-signal support or clearly repeated behavior

        static func < (lhs: ConfidenceTier, rhs: ConfidenceTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A single evaluated trait with its progression tier.
    private struct ProgressiveTrait {
        let family: String         // signal family key (for dedup across tiers)
        let tier: ConfidenceTier
        let phrase: String
        let specificity: Int       // higher = more specific (named context > generic)
    }

    /// Generates a short paragraph (1–2 sentences) summarizing up to 2 earned behavioral traits.
    /// Traits progress through 3 confidence stages as signals accumulate:
    ///   low → cautious early-signal language
    ///   medium → clearer moderate language
    ///   high → earned trait language
    /// Returns nil if no signals reach even the low threshold.
    func generateEmergingStrengthsParagraph() async -> String? {
        guard AuthService.shared.currentUser?.id != nil else { return nil }
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        // ── Gather raw signals ──

        // Messages sent after events (follow-through)
        let messageFeedItems = feedItems.filter {
            $0.feedType == .message &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }
        let messageCount = messageFeedItems.count

        // Connections that have conversations (follow-through via connection→message)
        let connectionItems = feedItems.filter {
            $0.feedType == .connection &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }
        let connectionActorIds = Set(connectionItems.compactMap { $0.actorProfileId })
        let messageActorIds = Set(messageFeedItems.compactMap { $0.actorProfileId })
        let connectionsFollowedByMessages = connectionActorIds.intersection(messageActorIds).count

        // Events attended (distinct event names in last 30 days)
        var eventNameCounts: [String: Int] = [:]
        for item in feedItems {
            guard let eventName = item.metadata?.eventName, !eventName.isEmpty else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            eventNameCounts[eventName.lowercased(), default: 0] += 1
        }
        if let currentEvent = EventJoinService.shared.currentEventName {
            eventNameCounts[currentEvent.lowercased(), default: 0] += 1
        }
        let distinctEventCount = eventNameCounts.count
        let dominantEvent = eventNameCounts.max(by: { $0.value < $1.value })

        // Connection clusters/themes (shared interests across connections)
        var themeConnections: [String: Set<UUID>] = [:]
        for item in feedItems {
            guard item.feedType == .connection || item.feedType == .encounter else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            guard let actorId = item.actorProfileId else { continue }
            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard key.count >= 2, !Self.vagueWords.contains(key) else { continue }
                    themeConnections[key, default: []].insert(actorId)
                }
            }
        }
        let multiPersonThemes = themeConnections.filter { $0.value.count >= 2 }
        let distinctClusterCount = multiPersonThemes.count
        let topConnectorTheme = multiPersonThemes.max(by: { $0.value.count < $1.value.count })

        // Thematic engagement
        let user = AuthService.shared.currentUser
        let interests = user?.interests ?? []
        let skills = user?.skills ?? []
        var themeInteractionCount: [String: Int] = [:]
        for item in feedItems {
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            if let eventName = item.metadata?.eventName {
                for theme in extractTopicWords(from: eventName) {
                    themeInteractionCount[theme, default: 0] += 1
                }
            }
            if let shared = item.metadata?.sharedInterests {
                for interest in shared {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(key) else { continue }
                    themeInteractionCount[key, default: 0] += 1
                }
            }
        }
        for interest in interests {
            let key = normalizeInterest(interest)
            if themeInteractionCount[key] != nil {
                themeInteractionCount[key]! += 1
            }
        }
        for skill in skills {
            let key = normalizeInterest(skill)
            if themeInteractionCount[key] != nil {
                themeInteractionCount[key]! += 1
            }
        }
        // Top theme by interaction count (no minimum yet — tier logic handles thresholds)
        let topTheme = themeInteractionCount
            .filter { !Self.vagueWords.contains($0.key) }
            .max(by: { $0.value < $1.value })

        // ── Evaluate each signal family across 3 tiers ──
        // For each family, compute the highest tier earned. Only that tier's phrase is kept.

        var bestPerFamily: [String: ProgressiveTrait] = [:]

        // A. Follow-through
        //   high:   messages ≥ 2 AND connections→messages ≥ 2
        //   medium: messages ≥ 2 OR connections→messages ≥ 2
        //   low:    messages ≥ 1 AND at least 1 connection exists
        let familyFollowThrough = "follow-through"
        if messageCount >= 2 && connectionsFollowedByMessages >= 2 {
            bestPerFamily[familyFollowThrough] = ProgressiveTrait(
                family: familyFollowThrough, tier: .high,
                phrase: "They often follow up after events.",
                specificity: 1
            )
        } else if messageCount >= 2 || connectionsFollowedByMessages >= 2 {
            bestPerFamily[familyFollowThrough] = ProgressiveTrait(
                family: familyFollowThrough, tier: .medium,
                phrase: "Showing signs of following up after events.",
                specificity: 1
            )
        } else if messageCount >= 1 && !connectionItems.isEmpty {
            bestPerFamily[familyFollowThrough] = ProgressiveTrait(
                family: familyFollowThrough, tier: .low,
                phrase: "Starting to follow up after events.",
                specificity: 1
            )
        }

        // B. Consistency
        //   high:   ≥ 3 distinct events + dominant event with ≥ 2 appearances
        //   medium: ≥ 3 distinct events (no dominant)  OR  ≥ 2 events + message activity
        //   low:    ≥ 1 event + at least 1 other signal (message or encounter)
        let familyConsistency = "consistency"
        let hasEncounterActivity = feedItems.contains {
            $0.feedType == .encounter &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }

        if distinctEventCount >= 3, let dominant = dominantEvent, dominant.value >= 2 {
            let originalName = feedItems
                .compactMap { $0.metadata?.eventName }
                .first { $0.lowercased() == dominant.key } ?? dominant.key
            bestPerFamily[familyConsistency] = ProgressiveTrait(
                family: familyConsistency, tier: .high,
                phrase: "They regularly attend \(originalName) events.",
                specificity: 3
            )
        } else if distinctEventCount >= 3 {
            bestPerFamily[familyConsistency] = ProgressiveTrait(
                family: familyConsistency, tier: .high,
                phrase: "They consistently show up in community gatherings.",
                specificity: 1
            )
        } else if distinctEventCount >= 2 && (messageCount >= 1 || hasEncounterActivity) {
            bestPerFamily[familyConsistency] = ProgressiveTrait(
                family: familyConsistency, tier: .medium,
                phrase: "Showing up at community events.",
                specificity: 1
            )
        } else if distinctEventCount >= 1 && (messageCount >= 1 || hasEncounterActivity) {
            bestPerFamily[familyConsistency] = ProgressiveTrait(
                family: familyConsistency, tier: .low,
                phrase: "Beginning to explore community events.",
                specificity: 1
            )
        }

        // C. Connector behavior
        //   high:   ≥ 2 clusters + top theme with ≥ 3 people
        //   medium: ≥ 2 clusters (smaller groups)
        //   low:    ≥ 1 cluster with ≥ 2 people  OR  connections across ≥ 2 event contexts
        let familyConnector = "connector"
        let connectionEventIds = Set(connectionItems.compactMap { $0.eventId })

        if distinctClusterCount >= 2, let top = topConnectorTheme, top.value.count >= 3 {
            bestPerFamily[familyConnector] = ProgressiveTrait(
                family: familyConnector, tier: .high,
                phrase: "They connect others around \(top.key).",
                specificity: 3
            )
        } else if distinctClusterCount >= 2 {
            bestPerFamily[familyConnector] = ProgressiveTrait(
                family: familyConnector, tier: .high,
                phrase: "They bring people together across different groups.",
                specificity: 2
            )
        } else if multiPersonThemes.count >= 1 {
            let themeName = multiPersonThemes.first?.key ?? ""
            bestPerFamily[familyConnector] = ProgressiveTrait(
                family: familyConnector, tier: .medium,
                phrase: "Engaging with people around \(themeName).",
                specificity: 2
            )
        } else if connectionEventIds.count >= 2 {
            bestPerFamily[familyConnector] = ProgressiveTrait(
                family: familyConnector, tier: .low,
                phrase: "Starting to connect across different events.",
                specificity: 1
            )
        }

        // D. Thematic engagement
        //   high:   theme interaction count ≥ 4 + user interest/skill match
        //   medium: theme interaction count ≥ 2
        //   low:    theme interaction count == 1 + user interest/skill match
        let familyThematic = "thematic"
        if let theme = topTheme {
            let userAnchors = (interests + skills).map { normalizeInterest($0) }
            let matchesUserProfile = userAnchors.contains(theme.key)

            if theme.value >= 4 && matchesUserProfile {
                bestPerFamily[familyThematic] = ProgressiveTrait(
                    family: familyThematic, tier: .high,
                    phrase: "They are active in conversations around \(theme.key).",
                    specificity: 3
                )
            } else if theme.value >= 2 {
                bestPerFamily[familyThematic] = ProgressiveTrait(
                    family: familyThematic, tier: .medium,
                    phrase: "Engaging regularly in \(theme.key).",
                    specificity: 2
                )
            } else if theme.value >= 1 && matchesUserProfile {
                bestPerFamily[familyThematic] = ProgressiveTrait(
                    family: familyThematic, tier: .low,
                    phrase: "Early signs of activity around \(theme.key).",
                    specificity: 1
                )
            }
        }

        // ── Trait selection ──
        // Collect all families that produced at least one tier.
        let allTraits = Array(bestPerFamily.values)
        guard !allTraits.isEmpty else { return nil }

        // Rank: tier (high > medium > low), then specificity, then family name for stability.
        let ranked = allTraits.sorted {
            if $0.tier != $1.tier { return $0.tier > $1.tier }
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            return $0.family < $1.family
        }

        let selected = Array(ranked.prefix(2))

        // ── Compose paragraph ──
        if selected.count == 2 {
            return "\(selected[0].phrase) \(selected[1].phrase)"
        } else if selected.count == 1 {
            return selected[0].phrase
        }

        return nil
    }

    // MARK: - Debug Summary

    /// Lightweight summary of all intelligence signals, thresholds, and reasoning.
    /// Used by the Intelligence Debug panel — never shown to end users.
    struct DebugProfileSummary {
        struct SignalSnapshot {
            let messageCount: Int
            let connectionCount: Int
            let encounterCount: Int
            let connectionsFollowedByMessages: Int
            let distinctEventCount: Int
            let dominantEvent: String?
            let dominantEventHits: Int
            let distinctClusterCount: Int
            let topConnectorTheme: String?
            let topConnectorThemePeople: Int
            let topTheme: String?
            let topThemeInteractions: Int
            let activeThemes: [String]
            let hasEncounterActivity: Bool
        }

        struct TraitEvaluation {
            let family: String
            let tier: String       // "low", "medium", "high", or "none"
            let phrase: String?
            let reason: String     // why this tier was chosen or why it failed
        }

        /// Debug evidence for a single earned trait candidate.
        struct EarnedTraitEvidence {
            let traitKey: String
            let traitName: String
            let qualified: Bool
            let outputText: String?
            let metrics: [Metric]

            struct Metric {
                let label: String
                let actual: String
                let required: String
                let met: Bool
            }
        }

        let signals: SignalSnapshot
        let traitEvaluations: [TraitEvaluation]
        let traitEvidence: [EarnedTraitEvidence]
        let latelyLines: [String]
        let emergingStrengthsParagraph: String?

        /// Top proximity interaction from encounters (name + duration)
        let topProximityInteraction: String?
    }

    /// Generates a full debug summary by reusing existing signal-gathering paths.
    func debugSummary() async -> DebugProfileSummary {
        let feedItems = FeedService.shared.feedItems
        let now = Date()

        // ── Gather signals (same logic as generateEmergingStrengthsParagraph) ──

        let messageFeedItems = feedItems.filter {
            $0.feedType == .message &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }
        let messageCount = messageFeedItems.count

        let connectionItems = feedItems.filter {
            $0.feedType == .connection &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }
        let connectionActorIds = Set(connectionItems.compactMap { $0.actorProfileId })
        let messageActorIds = Set(messageFeedItems.compactMap { $0.actorProfileId })
        let connectionsFollowedByMessages = connectionActorIds.intersection(messageActorIds).count

        let encounterItems = feedItems.filter {
            $0.feedType == .encounter &&
            ($0.createdAt.map { now.timeIntervalSince($0) < Weight.thirtyDays } ?? false)
        }
        let encounterCount = encounterItems.count
        let hasEncounterActivity = encounterCount > 0

        // Top proximity interaction
        let topEncounter = encounterItems
            .sorted { ($0.metadata?.overlapSeconds ?? 0) > ($1.metadata?.overlapSeconds ?? 0) }
            .first
        let topProximity: String? = topEncounter.flatMap { item in
            let name = item.metadata?.actorName ?? "Unknown"
            let secs = item.metadata?.overlapSeconds ?? 0
            let mins = secs / 60
            return mins > 0 ? "\(name), \(mins) min" : "\(name), \(secs)s"
        }

        var eventNameCounts: [String: Int] = [:]
        for item in feedItems {
            guard let eventName = item.metadata?.eventName, !eventName.isEmpty else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            eventNameCounts[eventName.lowercased(), default: 0] += 1
        }
        if let currentEvent = EventJoinService.shared.currentEventName {
            eventNameCounts[currentEvent.lowercased(), default: 0] += 1
        }
        let distinctEventCount = eventNameCounts.count
        let dominantEvent = eventNameCounts.max(by: { $0.value < $1.value })

        var themeConnections: [String: Set<UUID>] = [:]
        for item in feedItems {
            guard item.feedType == .connection || item.feedType == .encounter else { continue }
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            guard let actorId = item.actorProfileId else { continue }
            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard key.count >= 2, !Self.vagueWords.contains(key) else { continue }
                    themeConnections[key, default: []].insert(actorId)
                }
            }
        }
        let multiPersonThemes = themeConnections.filter { $0.value.count >= 2 }
        let distinctClusterCount = multiPersonThemes.count
        let topConnectorTheme = multiPersonThemes.max(by: { $0.value.count < $1.value.count })

        let user = AuthService.shared.currentUser
        let interests = user?.interests ?? []
        let skills = user?.skills ?? []
        var themeInteractionCount: [String: Int] = [:]
        for item in feedItems {
            guard let date = item.createdAt, now.timeIntervalSince(date) < Weight.thirtyDays else { continue }
            if let eventName = item.metadata?.eventName {
                for theme in extractTopicWords(from: eventName) {
                    themeInteractionCount[theme, default: 0] += 1
                }
            }
            if let shared = item.metadata?.sharedInterests {
                for interest in shared {
                    let key = interest.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !Self.vagueWords.contains(key) else { continue }
                    themeInteractionCount[key, default: 0] += 1
                }
            }
        }
        for interest in interests {
            let key = normalizeInterest(interest)
            if themeInteractionCount[key] != nil { themeInteractionCount[key]! += 1 }
        }
        for skill in skills {
            let key = normalizeInterest(skill)
            if themeInteractionCount[key] != nil { themeInteractionCount[key]! += 1 }
        }
        let topTheme = themeInteractionCount
            .filter { !Self.vagueWords.contains($0.key) }
            .max(by: { $0.value < $1.value })

        let activeThemes = themeInteractionCount
            .filter { $0.value >= 2 && !Self.vagueWords.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }

        let signals = DebugProfileSummary.SignalSnapshot(
            messageCount: messageCount,
            connectionCount: connectionItems.count,
            encounterCount: encounterCount,
            connectionsFollowedByMessages: connectionsFollowedByMessages,
            distinctEventCount: distinctEventCount,
            dominantEvent: dominantEvent?.key,
            dominantEventHits: dominantEvent?.value ?? 0,
            distinctClusterCount: distinctClusterCount,
            topConnectorTheme: topConnectorTheme?.key,
            topConnectorThemePeople: topConnectorTheme?.value.count ?? 0,
            topTheme: topTheme?.key,
            topThemeInteractions: topTheme?.value ?? 0,
            activeThemes: activeThemes,
            hasEncounterActivity: hasEncounterActivity
        )

        // ── Evaluate trait families (mirrors generateEmergingStrengthsParagraph) ──

        var evals: [DebugProfileSummary.TraitEvaluation] = []

        // Follow-through
        if messageCount >= 2 && connectionsFollowedByMessages >= 2 {
            evals.append(.init(family: "follow-through", tier: "high", phrase: "They often follow up after events.", reason: "msgs=\(messageCount)≥2 AND conn→msg=\(connectionsFollowedByMessages)≥2"))
        } else if messageCount >= 2 || connectionsFollowedByMessages >= 2 {
            evals.append(.init(family: "follow-through", tier: "medium", phrase: "Showing signs of following up after events.", reason: "msgs=\(messageCount) OR conn→msg=\(connectionsFollowedByMessages) (one ≥2)"))
        } else if messageCount >= 1 && !connectionItems.isEmpty {
            evals.append(.init(family: "follow-through", tier: "low", phrase: "Starting to follow up after events.", reason: "msgs=\(messageCount)≥1 AND connections exist"))
        } else {
            evals.append(.init(family: "follow-through", tier: "none", phrase: nil, reason: "msgs=\(messageCount), conn→msg=\(connectionsFollowedByMessages), connections=\(connectionItems.count) — insufficient"))
        }

        // Consistency
        let connectionEventIds = Set(connectionItems.compactMap { $0.eventId })
        if distinctEventCount >= 3, let dom = dominantEvent, dom.value >= 2 {
            evals.append(.init(family: "consistency", tier: "high", phrase: "They regularly attend \(dom.key) events.", reason: "events=\(distinctEventCount)≥3, dominant=\(dom.key)×\(dom.value)"))
        } else if distinctEventCount >= 3 {
            evals.append(.init(family: "consistency", tier: "high", phrase: "They consistently show up in community gatherings.", reason: "events=\(distinctEventCount)≥3, no dominant"))
        } else if distinctEventCount >= 2 && (messageCount >= 1 || hasEncounterActivity) {
            evals.append(.init(family: "consistency", tier: "medium", phrase: "Showing up at community events.", reason: "events=\(distinctEventCount)≥2 + supporting activity"))
        } else if distinctEventCount >= 1 && (messageCount >= 1 || hasEncounterActivity) {
            evals.append(.init(family: "consistency", tier: "low", phrase: "Beginning to explore community events.", reason: "events=\(distinctEventCount)≥1 + supporting activity"))
        } else {
            evals.append(.init(family: "consistency", tier: "none", phrase: nil, reason: "events=\(distinctEventCount), encounters=\(hasEncounterActivity), msgs=\(messageCount) — insufficient"))
        }

        // Connector
        if distinctClusterCount >= 2, let top = topConnectorTheme, top.value.count >= 3 {
            evals.append(.init(family: "connector", tier: "high", phrase: "They connect others around \(top.key).", reason: "clusters=\(distinctClusterCount)≥2, top=\(top.key)×\(top.value.count)people"))
        } else if distinctClusterCount >= 2 {
            evals.append(.init(family: "connector", tier: "high", phrase: "They bring people together across different groups.", reason: "clusters=\(distinctClusterCount)≥2"))
        } else if multiPersonThemes.count >= 1 {
            let name = multiPersonThemes.first?.key ?? ""
            evals.append(.init(family: "connector", tier: "medium", phrase: "Engaging with people around \(name).", reason: "1 multi-person theme: \(name)"))
        } else if connectionEventIds.count >= 2 {
            evals.append(.init(family: "connector", tier: "low", phrase: "Starting to connect across different events.", reason: "connections across \(connectionEventIds.count) events"))
        } else {
            evals.append(.init(family: "connector", tier: "none", phrase: nil, reason: "clusters=\(distinctClusterCount), connEventIds=\(connectionEventIds.count) — insufficient"))
        }

        // Thematic
        if let theme = topTheme {
            let userAnchors = (interests + skills).map { normalizeInterest($0) }
            let matchesProfile = userAnchors.contains(theme.key)
            if theme.value >= 4 && matchesProfile {
                evals.append(.init(family: "thematic", tier: "high", phrase: "They are active in conversations around \(theme.key).", reason: "interactions=\(theme.value)≥4 + profile match"))
            } else if theme.value >= 2 {
                evals.append(.init(family: "thematic", tier: "medium", phrase: "Engaging regularly in \(theme.key).", reason: "interactions=\(theme.value)≥2"))
            } else if theme.value >= 1 && matchesProfile {
                evals.append(.init(family: "thematic", tier: "low", phrase: "Early signs of activity around \(theme.key).", reason: "interactions=\(theme.value), profile match=true"))
            } else {
                evals.append(.init(family: "thematic", tier: "none", phrase: nil, reason: "theme=\(theme.key), interactions=\(theme.value), profileMatch=\(matchesProfile) — insufficient"))
            }
        } else {
            evals.append(.init(family: "thematic", tier: "none", phrase: nil, reason: "no theme detected"))
        }

        return DebugProfileSummary(
            signals: signals,
            traitEvaluations: evals,
            traitEvidence: evaluateEarnedTraitEvidence(
                feedItems: feedItems,
                targetUser: user,
                topicScores: themeInteractionCount.mapValues { Double($0) }
            ),
            latelyLines: latelyLines,
            emergingStrengthsParagraph: emergingStrengthsParagraph,
            topProximityInteraction: topProximity
        )
    }

    // MARK: - Token Normalization

    /// Maps raw event-name tokens to human-readable theme labels.
    /// Only mapped tokens appear in output phrases — unmapped tokens are dropped.
    private static let tokenThemeMap: [String: String] = [
        // Tech / engineering
        "hacker":      "startups",
        "hackathon":   "startups",
        "hack":        "startups",
        "hacks":       "startups",
        "startup":     "startups",
        "startups":    "startups",
        "founder":     "startups",
        "founders":    "startups",
        "entrepreneur":"startups",
        "venture":     "startups",
        "pitch":       "startups",
        "demo":        "startups",
        "launch":      "startups",
        "accelerator": "startups",
        "incubator":   "startups",

        // AI / ML
        "ai":          "AI",
        "artificial":  "AI",
        "intelligence":"AI",
        "machine":     "machine learning",
        "learning":    "machine learning",
        "llm":         "AI",
        "gpt":         "AI",
        "genai":       "AI",
        "deep":        "deep learning",
        "neural":      "AI",

        // Design
        "design":      "design",
        "ux":          "design",
        "ui":          "design",
        "figma":       "design",
        "creative":    "design",
        "product":     "product",

        // Health
        "health":      "health",
        "healthcare":  "health",
        "biotech":     "biotech",
        "bio":         "biotech",
        "medical":     "health",
        "wellness":    "health",

        // Web / dev
        "web":         "web dev",
        "frontend":    "web dev",
        "backend":     "engineering",
        "fullstack":   "engineering",
        "devops":      "engineering",
        "cloud":       "cloud",
        "aws":         "cloud",
        "mobile":      "mobile",
        "ios":         "mobile",
        "android":     "mobile",
        "swift":       "mobile",
        "react":       "web dev",
        "python":      "engineering",
        "rust":        "engineering",
        "golang":      "engineering",

        // Data
        "data":        "data",
        "analytics":   "data",
        "science":     "data science",

        // Crypto / web3
        "crypto":      "crypto",
        "blockchain":  "crypto",
        "web3":        "crypto",
        "defi":        "crypto",
        "nft":         "crypto",

        // Community / events
        "theater":     "tech events",
        "theatre":     "tech events",
        "summit":      "tech events",
        "fest":        "tech events",
        "expo":        "tech events",
        "forum":       "tech events",

        // Business
        "business":    "business",
        "marketing":   "marketing",
        "growth":      "growth",
        "sales":       "business",
        "finance":     "finance",
        "fintech":     "fintech",

        // Misc concrete
        "gaming":      "gaming",
        "game":        "gaming",
        "music":       "music",
        "art":         "art",
        "education":   "education",
        "climate":     "climate",
        "sustainability":"climate",
        "robotics":    "robotics",
        "hardware":    "hardware",
        "security":    "security",
        "cyber":       "security",
        "open":        "open source",
        "source":      "open source",
        "oss":         "open source",
    ]

    // MARK: - Helpers

    /// Public accessor for theme extraction. Used by HomeStateResolver for gap intelligence.
    func extractTopicWordsPublic(from eventName: String) -> [String] {
        extractTopicWords(from: eventName)
    }

    /// Extracts tokens from an event name, normalizes them through the theme map,
    /// and returns only mapped, human-readable themes. Unmapped tokens are dropped.
    private func extractTopicWords(from eventName: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "at", "in", "on", "for", "and", "or", "of",
            "to", "with", "by", "event", "events", "meetup", "conference",
            "workshop", "session", "talk", "day", "night", "week", "2024",
            "2025", "2026", "vol", "edition", "part", "series", "group",
            "club", "org", "inc", "llc", "presents", "hosted", "show",
            "tech", "annual", "monthly", "weekly", "virtual", "live"
        ]

        let rawTokens = eventName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 2 && !stopWords.contains($0) }

        // Map tokens to themes, deduplicating
        var seen: Set<String> = []
        var themes: [String] = []
        for token in rawTokens {
            if let theme = Self.tokenThemeMap[token], !seen.contains(theme) {
                seen.insert(theme)
                themes.append(theme)
            }
        }

        return themes
    }

    /// Normalizes a user interest/skill string through the theme map.
    /// Returns the mapped theme if found, otherwise returns the original
    /// lowercased string (interests are user-authored, so they're already readable).
    private func normalizeInterest(_ raw: String) -> String {
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Try direct map
        if let theme = Self.tokenThemeMap[key] { return theme }
        // Try first word
        let firstWord = key.components(separatedBy: " ").first ?? key
        if let theme = Self.tokenThemeMap[firstWord] { return theme }
        // User-authored interests are already readable — pass through
        return key
    }
}
