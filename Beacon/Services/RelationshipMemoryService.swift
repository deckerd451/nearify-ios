import Foundation
import Combine
import Supabase

/// Derives persistent relationship memory from existing data sources.
/// No new tables, no new scoring logic, no duplication of Home intelligence.
///
/// Data sources (all existing, all persisted):
///   - feed_items (encounters, connections, messages)
///   - encounters (BLE overlap data)
///   - connections (accepted relationships)
///   - conversations (messaging threads)
///
/// This service READS existing data and DERIVES cumulative relationship state.
/// It does NOT generate feed items, compute scores, or modify any existing service.
@MainActor
final class RelationshipMemoryService: ObservableObject {

    static let shared = RelationshipMemoryService()

    @Published private(set) var relationships: [RelationshipMemory] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    private let supabase = AppEnvironment.shared.supabaseClient
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    private init() {}

    // MARK: - Public API

    func requestRefresh(reason: String) {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task {
            await buildRelationships()
            isRefreshing = false
            #if DEBUG
            print("[RelMemory] ✅ Refresh complete (\(reason)): \(relationships.count) relationships")
            #endif
        }
    }

    /// Sectioned output for the People view.
    /// Strict priority: each person assigned to highest-priority section only.
    /// Small datasets (≤3 people): collapse into single strongest section.
    /// Larger datasets: Follow Up → Strongest → Recurring → Recent → Connected.
    func sectioned() -> [(section: PeopleSection, items: [RelationshipMemory])] {
        let now = Date()

        // Small dataset: avoid over-sectioning. Show one meaningful section.
        if relationships.count <= 3 {
            let sorted = relationships.sorted { $0.relationshipStrength > $1.relationshipStrength }
            let hasFollowUp = sorted.contains { $0.needsFollowUp }
            let section: PeopleSection = hasFollowUp ? .followUp : .strongest
            return [(section, sorted)]
        }

        var result: [(PeopleSection, [RelationshipMemory])] = []
        var claimed = Set<UUID>()

        // 1. Follow Up (highest priority — actionable)
        let followUp = relationships
            .filter { $0.needsFollowUp }
            .sorted { $0.relationshipStrength > $1.relationshipStrength }
            .prefix(3)

        if !followUp.isEmpty {
            result.append((.followUp, Array(followUp)))
            claimed.formUnion(followUp.map(\.profileId))
        }

        // 2. Strongest (deep relationships)
        let strongest = relationships
            .filter { $0.relationshipStrength > 0 && !claimed.contains($0.profileId) }
            .sorted { $0.relationshipStrength > $1.relationshipStrength }
            .prefix(5)

        if !strongest.isEmpty {
            result.append((.strongest, Array(strongest)))
            claimed.formUnion(strongest.map(\.profileId))
        }

        // 3. Recurring (repeat encounters — only if adds new people)
        let recurring = relationships
            .filter { $0.encounterCount >= 2 && !claimed.contains($0.profileId) }
            .sorted { $0.encounterCount > $1.encounterCount }
            .prefix(5)

        if !recurring.isEmpty {
            result.append((.recurring, Array(recurring)))
            claimed.formUnion(recurring.map(\.profileId))
        }

        // 4. Recent (last 48 hours — only if adds new people)
        let recent = relationships
            .filter { r in
                guard !claimed.contains(r.profileId) else { return false }
                let lastDate = [r.lastEncounterAt, r.lastMessageAt, r.connectionDate]
                    .compactMap { $0 }
                    .max()
                guard let d = lastDate else { return false }
                return now.timeIntervalSince(d) < 2 * 86400
            }
            .sorted { a, b in
                let aDate = [a.lastEncounterAt, a.lastMessageAt, a.connectionDate]
                    .compactMap { $0 }
                    .max() ?? .distantPast
                let bDate = [b.lastEncounterAt, b.lastMessageAt, b.connectionDate]
                    .compactMap { $0 }
                    .max() ?? .distantPast
                return aDate > bDate
            }
            .prefix(5)

        if !recent.isEmpty {
            result.append((.recent, Array(recent)))
            claimed.formUnion(recent.map(\.profileId))
        }

        // 5. Connected (remainder — only if unclaimed)
        let connected = relationships
            .filter { $0.connectionStatus == .accepted && !claimed.contains($0.profileId) }
            .sorted { ($0.connectionDate ?? .distantPast) > ($1.connectionDate ?? .distantPast) }
            .prefix(5)

        if !connected.isEmpty {
            result.append((.connected, Array(connected)))
        }

        return result
    }

    // MARK: - Build Pipeline

    private func buildRelationships() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }

        // Skip network-dependent rebuild when offline — existing relationships remain
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("[NearbyMode] skipping backend feature: relationship memory refresh")
            #endif
            return
        }

        isLoading = true
        defer { isLoading = false }

        // 1. Gather all feed items (already loaded by FeedService)
        let feedItems = FeedService.shared.feedItems

        // 2. Gather connections
        let connections: [Connection]
        do {
            connections = try await ConnectionService.shared.fetchConnections()
        } catch {
            connections = []
            print("[RelMemory] ⚠️ Failed to fetch connections: \(error)")
        }

        // 3. Gather conversations
        let conversations: [Conversation]
        do {
            conversations = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .execute()
                .value
        } catch {
            conversations = []
            print("[RelMemory] ⚠️ Failed to fetch conversations: \(error)")
        }

        // 4. Gather last message times per conversation
        var lastMessageMap: [UUID: Date] = [:] // conversationId → lastMessageDate
        for convo in conversations {
            let msgs: [Message]? = try? await supabase
                .from("messages")
                .select("*")
                .eq("conversation_id", value: convo.id.uuidString)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value

            if let ts = msgs?.first?.createdAt {
                lastMessageMap[convo.id] = ts
            }
        }

        // 5. Build profile index from feed metadata + connections
        var profileNames: [UUID: String] = [:]
        var profileAvatars: [UUID: String] = [:]

        for item in feedItems {
            if let id = item.actorProfileId {
                if let name = item.metadata?.actorName {
                    profileNames[id] = name
                }
                if let url = item.metadata?.actorAvatarUrl {
                    profileAvatars[id] = url
                }
            }
        }

        for conn in connections {
            let other = conn.otherUser(for: myId)
            profileNames[other.id] = other.name
        }

        // 6. Aggregate per other-profile
        var otherProfileIds = Set<UUID>()

        for item in feedItems {
            if let id = item.actorProfileId, id != myId {
                otherProfileIds.insert(id)
            }
        }

        for conn in connections {
            otherProfileIds.insert(conn.otherUser(for: myId).id)
        }

        for convo in conversations {
            otherProfileIds.insert(convo.otherParticipant(for: myId))
        }

        var built: [RelationshipMemory] = []

        for profileId in otherProfileIds {
            let memory = buildSingleRelationship(
                myId: myId,
                profileId: profileId,
                feedItems: feedItems,
                connections: connections,
                conversations: conversations,
                lastMessageMap: lastMessageMap,
                profileNames: profileNames,
                profileAvatars: profileAvatars
            )

            if let memory {
                built.append(memory)
            }
        }

        relationships = built.sorted { $0.relationshipStrength > $1.relationshipStrength }
        lastRefresh = Date()

        // Populate offline profile cache
        ProfileCache.shared.storeRelationships(relationships)
    }

    // MARK: - Single Relationship Builder

    private func buildSingleRelationship(
        myId: UUID,
        profileId: UUID,
        feedItems: [FeedItem],
        connections: [Connection],
        conversations: [Conversation],
        lastMessageMap: [UUID: Date],
        profileNames: [UUID: String],
        profileAvatars: [UUID: String]
    ) -> RelationshipMemory? {
        let name = profileNames[profileId] ?? "Unknown"
        let avatar = profileAvatars[profileId]

        // Filter feed items for this profile
        let theirItems = feedItems.filter { $0.actorProfileId == profileId }

        // Encounters
        let encounterItems = theirItems.filter { $0.feedType == .encounter }
        let encounterCount = encounterItems.count
        let totalOverlap = encounterItems.reduce(0) { $0 + ($1.metadata?.overlapSeconds ?? 0) }
        let lastEncounter = encounterItems.compactMap(\.createdAt).max()

        // Connection
        let conn = connections.first { connection in
            let other = connection.otherUser(for: myId)
            return other.id == profileId
        }

        let connStatus: RelationshipConnectionStatus
        if let conn {
            connStatus = conn.status == "accepted" ? .accepted : .pending
        } else {
            connStatus = .none
        }
        let connDate = conn?.createdAt

        // Conversation / messaging
        let convo = conversations.first { $0.otherParticipant(for: myId) == profileId }
        let hasConvo = convo != nil
        let lastMsg = convo.flatMap { lastMessageMap[$0.id] }

        // Shared interests (union from all encounter metadata)
        var interests = Set<String>()
        for item in encounterItems {
            for interest in item.metadata?.sharedInterests ?? [] {
                interests.insert(interest)
            }
        }

        // Event contexts (distinct event names)
        var events = Set<String>()
        for item in theirItems {
            if let eventName = item.metadata?.eventName, !eventName.isEmpty {
                events.insert(eventName)
            }
        }

        // Fallback: if no event names in feed metadata, use currently joined event
        var eventList = Array(events)
        if eventList.isEmpty,
           let currentEvent = EventJoinService.shared.currentEventName,
           !currentEvent.isEmpty {
            eventList = [currentEvent]
        }

        #if DEBUG
        print("[RelMemory] \(name) eventList=\(eventList)")
        #endif

        // Compute lastDate FIRST — needed for both follow-up and strength
        let lastDate = [lastEncounter, lastMsg, connDate].compactMap { $0 }.max()

        // Needs follow-up: strong signal exists but no recent messaging
        let hasMeaningfulInteraction =
            totalOverlap >= 60 ||
            encounterCount >= 2 ||
            connStatus == .accepted

        let isRecentEnough =
            lastDate.map { Date().timeIntervalSince($0) < 5 * 86400 } ?? false

        let hasRecentMessage =
            lastMsg.map { Date().timeIntervalSince($0) < 86400 } ?? false

        let needsFollowUp =
            hasMeaningfulInteraction &&
            isRecentEnough &&
            !hasRecentMessage

        // Relationship strength: reuse temporal priority model from FeedPriorityScorer
        let age = lastDate.map { Date().timeIntervalSince($0) }

        let signalStrength = computeSignalStrength(
            encounterCount: encounterCount,
            totalOverlap: totalOverlap,
            isConnected: connStatus == .accepted,
            hasMessages: hasConvo
        )

        let strength = TemporalResolver.temporalPriority(
            lastSeenAge: age,
            signalStrength: signalStrength,
            encounterCount: encounterCount
        )

        // Skip if no meaningful signal at all
        guard encounterCount > 0 || connStatus != .none || hasConvo else { return nil }

        // Why line: explain why this person appears
        var why = generateWhyLine(
            name: name,
            encounterCount: encounterCount,
            totalOverlap: totalOverlap,
            connStatus: connStatus,
            hasConvo: hasConvo,
            lastMsg: lastMsg,
            events: eventList,
            sharedInterests: Array(interests),
            lastSeenAt: lastDate
        )

        // For follow-up candidates: replace time suffix with action-oriented phrase
        if needsFollowUp {
            if let dotRange = why.range(of: " · ", options: .backwards) {
                let base = String(why[..<dotRange.lowerBound])
                why = base + " · follow up"
            } else {
                why += " · follow up"
            }
        }

        return RelationshipMemory(
            profileId: profileId,
            name: name,
            avatarUrl: avatar,
            encounterCount: encounterCount,
            totalOverlapSeconds: totalOverlap,
            lastEncounterAt: lastEncounter,
            connectionStatus: connStatus,
            connectionDate: connDate,
            hasConversation: hasConvo,
            lastMessageAt: lastMsg,
            sharedInterests: Array(interests),
            eventContexts: Array(events),
            needsFollowUp: needsFollowUp,
            relationshipStrength: strength,
            whyLine: why
        )
    }

    // MARK: - Signal Strength (reuses existing model)

    private func computeSignalStrength(
        encounterCount: Int,
        totalOverlap: Int,
        isConnected: Bool,
        hasMessages: Bool
    ) -> Double {
        var strength: Double = 0

        if totalOverlap >= 900 {
            strength += 0.4
        } else if totalOverlap >= 300 {
            strength += 0.3
        } else if totalOverlap >= 60 {
            strength += 0.2
        }

        if isConnected {
            strength += 0.25
        }

        if hasMessages {
            strength += 0.25
        }

        if encounterCount >= 3 {
            strength += 0.1
        }

        return min(strength, 1.0)
    }

    // MARK: - Why Line Generator

    private func generateWhyLine(
        name: String,
        encounterCount: Int,
        totalOverlap: Int,
        connStatus: RelationshipConnectionStatus,
        hasConvo: Bool,
        lastMsg: Date?,
        events: [String],
        sharedInterests: [String],
        lastSeenAt: Date? = nil
    ) -> String {
        let timeRef = relativeTime(lastSeenAt)
        let event = events.first
        let timeSuffix = timeRef.isEmpty ? "" : " · \(timeRef.trimmingCharacters(in: .whitespaces))"

        // Priority: richest interaction context first.
        // Pattern: "[Interaction] at [Event] · [Time]"
        // Connection-only fallback used ONLY when no interaction context exists.
        var primary: String

        if encounterCount >= 3, let event {
            primary = "Met \(encounterCount) times at \(event)\(timeSuffix)"
        } else if events.count >= 2 {
            let top2 = events.prefix(2).joined(separator: " and ")
            primary = "Seen at \(top2)\(timeSuffix)"
        } else if totalOverlap > 600, let event {
            primary = "Talked at \(event)\(timeSuffix)"
        } else if totalOverlap > 600 {
            primary = "Talked\(timeRef)"
        } else if encounterCount >= 2, let event {
            primary = "Met twice at \(event)\(timeSuffix)"
        } else if encounterCount >= 2 {
            primary = "Met twice\(timeRef)"
        } else if encounterCount >= 3 {
            primary = "Met \(encounterCount) times\(timeRef)"
        } else if let event {
            primary = "Met at \(event)\(timeSuffix)"
        } else if encounterCount >= 1 {
            primary = "Crossed paths\(timeRef)"
        } else if connStatus == .accepted {
            primary = "Connected\(timeRef)"
        } else {
            primary = "In your orbit"
        }

        // Append shared interest when it adds specificity
        if let top = sharedInterests.first, !top.isEmpty {
            primary += " · \(top)"
        }

        return primary
    }

    /// Converts a date to a relative time fragment for whyLine context.
    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }

        let age = Date().timeIntervalSince(date)
        if age < 3600 { return " just now" }
        if age < 86400 { return " today" }
        if age < 2 * 86400 { return " yesterday" }
        if age < 7 * 86400 { return " this week" }
        if age < 30 * 86400 { return " this month" }
        return " recently"
    }
}
