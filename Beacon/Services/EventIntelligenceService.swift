import Foundation
import Combine
import Supabase

/// Real-time event intelligence engine.
/// Computes "Top People Right Now" from encounters, connections, messaging,
/// and proximity — zero user action required.
@MainActor
final class EventIntelligenceService: ObservableObject {

    static let shared = EventIntelligenceService()

    @Published private(set) var topPeople: [RankedProfile] = []
    @Published private(set) var isLoading = false

    private let supabase = AppEnvironment.shared.supabaseClient
    private var isRefreshing = false
    private var lastAttendeeSignature = ""

    private init() {}

    // MARK: - Scoring Constants

    private enum Score {
        // Encounter strength (overlap_seconds)
        static let encounterStrong: Double  = 25  // >= 900s
        static let encounterMedium: Double  = 12  // >= 300s
        static let encounterLight: Double   = 5   // >= 60s

        // Recency of last interaction
        static let recency10Min: Double     = 20
        static let recency1Hour: Double     = 15
        static let recency6Hour: Double     = 10
        static let recency24Hour: Double    = 5

        // Relationship signals
        static let alreadyConnected: Double = 10

        // Messaging activity
        static let messagedRecent10Min: Double = 25
        static let messagedRecent1Hour: Double = 15
    }

    // MARK: - Public API

    /// Computes the top relevant people at the current event.
    /// Call on Event tab appear — no user action needed.
    func refresh() {
        guard let myId = AuthService.shared.currentUser?.id,
              let eventIdStr = EventJoinService.shared.currentEventID,
              let eventId = UUID(uuidString: eventIdStr) else {
            topPeople = []
            return
        }

        // Guard against overlapping refreshes
        guard !isRefreshing else {
            #if DEBUG
            print("[EventIntel] Refresh already running — skipping")
            #endif
            return
        }

        // Material-change check: skip if attendee list hasn't changed
        let currentSignature = EventAttendeesService.shared.attendees.map { $0.id.uuidString }.sorted().joined()
        if currentSignature == lastAttendeeSignature && !topPeople.isEmpty {
            #if DEBUG
            print("[EventIntel] Refresh skipped (no material change)")
            #endif
            return
        }

        #if DEBUG
        print("[EventIntel] Refresh requested")
        #endif

        isRefreshing = true
        isLoading = true
        Task {
            let results = await getTopRelevantPeople(
                eventId: eventId,
                viewerProfileId: myId,
                limit: 5
            )
            topPeople = results
            lastAttendeeSignature = currentSignature
            isLoading = false
            isRefreshing = false

            // Evaluate for notifications
            NotificationService.shared.evaluateEventIntelligence(results)

            #if DEBUG
            print("[EventIntel] Refresh complete — \(results.count) ranked profiles")
            #endif
        }
    }

    /// Core ranking function.
    func getTopRelevantPeople(
        eventId: UUID,
        viewerProfileId: UUID,
        limit: Int = 5
    ) async -> [RankedProfile] {

        let myId = viewerProfileId

        // 1. Get current attendees at this event
        let attendees = EventAttendeesService.shared.attendees
        guard !attendees.isEmpty else {
            #if DEBUG
            print("[EventIntel] No attendees, returning empty")
            #endif
            return []
        }

        // 2. Get connected profile IDs
        let connectedIds = AttendeeStateResolver.shared.connectedIds

        // 3. Get encounters for this event
        var encounterMap: [UUID: Encounter] = [:]
        do {
            let encounters: [Encounter] = try await supabase
                .from("encounters")
                .select("*")
                .eq("event_id", value: eventId.uuidString)
                .or("profile_a.eq.\(myId.uuidString),profile_b.eq.\(myId.uuidString)")
                .execute()
                .value

            for enc in encounters {
                let otherId = enc.otherProfile(for: myId)
                // Keep strongest encounter per person
                if let existing = encounterMap[otherId] {
                    if (enc.overlapSeconds ?? 0) > (existing.overlapSeconds ?? 0) {
                        encounterMap[otherId] = enc
                    }
                } else {
                    encounterMap[otherId] = enc
                }
            }
        } catch {
            print("[EventIntel] ⚠️ Failed to load encounters: \(error)")
        }

        // 4. Get recent messages (conversations with activity)
        var lastMessageTime: [UUID: Date] = [:]
        do {
            let conversations: [Conversation] = try await supabase
                .from("conversations")
                .select("*")
                .or("participant_a.eq.\(myId.uuidString),participant_b.eq.\(myId.uuidString)")
                .execute()
                .value

            for convo in conversations {
                let otherId = convo.otherParticipant(for: myId)

                let messages: [Message] = try await supabase
                    .from("messages")
                    .select("*")
                    .eq("conversation_id", value: convo.id.uuidString)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value

                if let latest = messages.first, let ts = latest.createdAt {
                    lastMessageTime[otherId] = ts
                }
            }
        } catch {
            print("[EventIntel] ⚠️ Failed to load messages: \(error)")
        }

        // 5. Build interaction signals and generate insights
        let viewerProfile = AuthService.shared.currentUser
        let signals = InteractionInsightService.shared.buildSignals(
            attendees: attendees,
            encounters: encounterMap,
            connectedIds: connectedIds,
            lastMessageTimes: lastMessageTime,
            viewerProfile: viewerProfile,
            myId: myId
        )
        let allInsights = InteractionInsightService.shared.generateInsights(from: signals)
        let insightMap = Dictionary(uniqueKeysWithValues: allInsights.map { ($0.profileId, $0) })

        // 6. Score each attendee (keep existing scoring + attach insight)
        var ranked: [RankedProfile] = []

        for attendee in attendees where attendee.id != myId {
            let pid = attendee.id
            var total: Double = 0
            var components: [String] = []

            // Encounter strength
            if let enc = encounterMap[pid] {
                let overlap = enc.overlapSeconds ?? 0
                let boost: Double
                if overlap >= 900      { boost = Score.encounterStrong }
                else if overlap >= 300 { boost = Score.encounterMedium }
                else if overlap >= 60  { boost = Score.encounterLight }
                else                   { boost = 0 }
                total += boost
                if boost > 0 { components.append("encounter=+\(Int(boost)) (\(overlap)s)") }
            }

            // Recency
            let lastInteraction = encounterMap[pid]?.lastSeenAt
                ?? lastMessageTime[pid]
                ?? attendee.lastSeen
            let recencyBoost = recencyScore(for: lastInteraction)
            total += recencyBoost
            if recencyBoost > 0 { components.append("recency=+\(Int(recencyBoost))") }

            // Connection status
            let isConn = connectedIds.contains(pid)
            if isConn {
                total += Score.alreadyConnected
                components.append("connected=+\(Int(Score.alreadyConnected))")
            }

            // Messaging activity
            if let msgTime = lastMessageTime[pid] {
                let age = Date().timeIntervalSince(msgTime)
                let msgBoost: Double
                if age < 600       { msgBoost = Score.messagedRecent10Min }
                else if age < 3600 { msgBoost = Score.messagedRecent1Hour }
                else               { msgBoost = 0 }
                total += msgBoost
                if msgBoost > 0 { components.append("messaged=+\(Int(msgBoost))") }
            }

            // Shared interests boost from insight layer
            let profileInsight = insightMap[pid]
            if let insight = profileInsight, !insight.sharedInterests.isEmpty {
                let interestBoost = min(Double(insight.sharedInterests.count) * 5.0, 20.0)
                total += interestBoost
                components.append("interests=+\(Int(interestBoost)) (\(insight.sharedInterests.count) shared)")
            }

            guard total > 0 else { continue }

            #if DEBUG
            let needLabel = profileInsight?.needState.rawValue ?? "none"
            print("[EventIntel] profile=\(attendee.name) score=\(Int(total)) need=\(needLabel) components=[\(components.joined(separator: ", "))]")
            #endif

            ranked.append(RankedProfile(
                profileId: pid,
                name: attendee.name,
                score: total,
                encounterStrength: encounterMap[pid]?.overlapSeconds ?? 0,
                isConnected: isConn,
                hasMessaged: lastMessageTime[pid] != nil,
                lastInteractionAt: lastInteraction,
                insight: profileInsight
            ))
        }

        return ranked
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Helpers

    private func recencyScore(for timestamp: Date?) -> Double {
        guard let ts = timestamp else { return 0 }
        let age = Date().timeIntervalSince(ts)
        if age < 600       { return Score.recency10Min }
        if age < 3600      { return Score.recency1Hour }
        if age < 21600     { return Score.recency6Hour }
        if age < 86400     { return Score.recency24Hour }
        return 0
    }
}

// MARK: - RankedProfile

struct RankedProfile: Identifiable {
    let id: UUID = UUID()
    let profileId: UUID
    let name: String
    let score: Double
    let encounterStrength: Int
    let isConnected: Bool
    let hasMessaged: Bool
    let lastInteractionAt: Date?
    let insight: ProfileInsight?
}
