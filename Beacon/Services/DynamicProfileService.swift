import Foundation
import Combine
import Supabase

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
            lastGenerated = Date()
            isLoading = false

            #if DEBUG
            print("[Lately] Generated \(lines.count) lines: \(lines)")
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

        // Step 3: Confidence filter — only include if score >= threshold
        let threshold: Double = 0.3
        let filtered = candidates
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }

        // Step 4: Max 3, no duplicates across categories
        var usedCategories: Set<Category> = []
        var result: [String] = []
        for candidate in filtered {
            guard !usedCategories.contains(candidate.category) else { continue }
            usedCategories.insert(candidate.category)
            result.append(candidate.line)
            if result.count >= 3 { break }
        }

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
        "people", "world", "things", "stuff", "ideas", "space"
    ]

    /// Category 1: Topic / Focus — prefers concrete nouns from events + interests.
    /// Two strong themes → "Exploring [t1] and [t2]"
    /// One strong theme  → "Focused lately on [t1]"
    /// Otherwise omit.
    private func generateTopicLine(
        user: User?,
        eventSignals: [EventSignal],
        connectionSignals: [ConnectionSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let interests = user?.interests ?? []
        let skills = user?.skills ?? []

        // Extract topic words from event names (weighted)
        let eventTopics = eventSignals.flatMap { signal -> [(String, Double)] in
            let words = extractTopicWords(from: signal.eventName)
            return words.map { ($0, signal.weight) }
        }

        // Build scored topic map — event-derived topics get full weight,
        // static profile fields get less so behavioral signal dominates.
        var topicScores: [String: Double] = [:]
        for (topic, weight) in eventTopics {
            topicScores[topic, default: 0] += weight
        }
        for interest in interests {
            let normalized = interest.lowercased()
            topicScores[normalized, default: 0] += 0.3
        }
        for skill in skills {
            let normalized = skill.lowercased()
            topicScores[normalized, default: 0] += 0.2
        }

        // Demote vague words — halve their score so concrete nouns win
        for key in topicScores.keys where Self.vagueWords.contains(key) {
            topicScores[key] = (topicScores[key] ?? 0) * 0.5
        }

        let sorted = topicScores.sorted { $0.value > $1.value }
        guard let first = sorted.first, first.value >= 0.4 else { return nil }

        // Pick top themes that clear a minimum bar
        let strong = sorted.filter { $0.value >= first.value * 0.5 }.prefix(3)
        let topThemes = strong.map { $0.key }
        let totalScore = strong.reduce(0.0) { $0 + $1.value }

        let line: String
        if topThemes.count >= 2 {
            line = "Exploring \(topThemes[0]) and \(topThemes[1])"
        } else {
            line = "Focused lately on \(topThemes[0])"
        }

        return (line, min(totalScore / 2.0, 1.0), .topic)
    }

    /// Category 2: People / Network — uses role clusters from encounter context.
    /// Two role clusters → "Meeting [r1] and [r2]"
    /// One role cluster  → "Meeting people around [theme]"
    /// Otherwise omit.
    private func generatePeopleLine(
        connectionSignals: [ConnectionSignal],
        encounterSignals: [EncounterSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let totalPeople = connectionSignals.count + encounterSignals.count
        let weightedScore = connectionSignals.reduce(0.0) { $0 + $1.weight }
            + encounterSignals.reduce(0.0) { $0 + $1.weight }

        guard totalPeople >= 2 else { return nil }

        // Try to extract role clusters from the names of people met.
        // Feed items carry shared_interests in metadata — use those as
        // a proxy for the "kind of people" the user is meeting.
        let feedItems = FeedService.shared.feedItems
        var roleCounts: [String: Double] = [:]
        for item in feedItems {
            guard item.feedType == .encounter || item.feedType == .connection else { continue }
            guard let date = item.createdAt else { continue }
            let w = Weight.forAge(Date().timeIntervalSince(date))
            guard w > 0 else { continue }

            if let interests = item.metadata?.sharedInterests {
                for interest in interests {
                    let key = interest.lowercased()
                    guard !Self.vagueWords.contains(key) else { continue }
                    roleCounts[key, default: 0] += w
                }
            }
        }

        let topRoles = roleCounts.sorted { $0.value > $1.value }.prefix(2).map { $0.key }

        let line: String
        if topRoles.count >= 2 {
            line = "Meeting people into \(topRoles[0]) and \(topRoles[1])"
        } else if let role = topRoles.first {
            line = "Meeting people around \(role)"
        } else if connectionSignals.count >= 3 {
            // Fallback: no role data, but enough volume to say something
            line = "Building new connections"
        } else {
            return nil
        }

        return (line, min(weightedScore / 3.0, 1.0), .people)
    }

    /// Category 3: Activity / Momentum — prefers named events over generic labels.
    /// Repeated named event → "Active at [event] events"
    /// Message + encounter follow-through → "Following up after recent events"
    /// Repeated attendance → "Showing up at [event]"
    /// Otherwise omit.
    private func generateActivityLine(
        eventSignals: [EventSignal],
        messageSignals: [MessageSignal],
        encounterSignals: [EncounterSignal]
    ) -> (line: String, score: Double, category: Category)? {
        let eventCount = eventSignals.count
        let messageCount = messageSignals.count
        let encounterCount = encounterSignals.count

        // Prefer named event specificity
        if eventCount >= 2 {
            let topEvent = eventSignals
                .sorted { $0.weight > $1.weight }
                .first?.eventName

            if let event = topEvent {
                let score = eventSignals.reduce(0.0) { $0 + $1.weight } / 2.0
                return ("Active at \(event) events", min(score, 1.0), .activity)
            }
        }

        // Follow-up behavior (messages after encounters)
        if messageCount >= 2 && encounterCount >= 1 {
            let score = messageSignals.reduce(0.0) { $0 + $1.weight } / 2.0
            return ("Following up after recent events", min(score, 1.0), .activity)
        }

        // Single named event with supporting activity
        if eventCount == 1, let event = eventSignals.first {
            if messageCount >= 1 || encounterCount >= 1 {
                let totalWeight = event.weight + messageSignals.reduce(0.0) { $0 + $1.weight }
                return ("Showing up at \(event.eventName)", min(totalWeight / 2.0, 1.0), .activity)
            }
            // Single event, no other activity — still worth showing if recent
            if event.weight >= 0.7 {
                return ("Active at \(event.eventName)", event.weight * 0.6, .activity)
            }
        }

        // Multiple events but no top event resolved (shouldn't happen, but guard)
        if eventCount >= 1 && (messageCount >= 1 || encounterCount >= 1) {
            let topEvent = eventSignals.sorted { $0.weight > $1.weight }.first?.eventName
            if let event = topEvent {
                return ("Showing up at \(event)", 0.4, .activity)
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Extracts meaningful topic words from event names.
    /// Strips stop words and returns lowercased tokens.
    /// Vague words are not stripped here — they're demoted in scoring instead,
    /// so they can still appear as a last resort.
    private func extractTopicWords(from eventName: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "at", "in", "on", "for", "and", "or", "of",
            "to", "with", "by", "event", "events", "meetup", "conference",
            "workshop", "session", "talk", "day", "night", "week", "2024",
            "2025", "2026", "vol", "edition", "part", "series", "group",
            "club", "org", "inc", "llc", "presents", "hosted"
        ]

        return eventName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}
