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

/// Generates "Lately" lines for the Profile tab.
/// Lightweight, client-side, derived from existing data sources.
/// Returns 0–3 short phrases reflecting recent activity patterns.
///
/// No Supabase schema changes. No new tables. No heavy AI.
@MainActor
final class DynamicProfileService: ObservableObject {

    static let shared = DynamicProfileService()

    @Published private(set) var latelyLines: [String] = []
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
            lastGenerated = Date()
            isLoading = false

            #if DEBUG
            print("[Lately] Generated \(lines.count) lines: \(lines)")
            print("[Lately] Signals: themes=\(currentSignals.topThemes) event=\(currentSignals.recentEventName ?? "none") momentum=\(currentSignals.hasFollowUpMomentum) sharedInterests=\(currentSignals.recentSharedInterests.count)")
            #endif
        }
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
        guard let myId = AuthService.shared.currentUser?.id else { return DynamicProfileSignals() }
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
