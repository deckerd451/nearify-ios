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

        // Material-change check: include encounter tracker state so new
        // proximity data triggers re-evaluation even if attendee list is stable.
        let attendeeSig = EventAttendeesService.shared.attendees.map { $0.id.uuidString }.sorted().joined()
        let trackerSig = EncounterService.shared.activeEncounters.values
            .map { "\($0.profileId.uuidString):\($0.totalSeconds)" }
            .sorted().joined()
        let currentSignature = attendeeSig + "|" + trackerSig
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

        // 3. Get encounters for this event (DB + in-memory tracker)
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

        // Supplement with in-memory tracker data (more current than DB).
        // The tracker accumulates overlap in real-time; the DB only updates
        // every 30s flush. Use whichever has more overlap seconds.
        for (profileId, tracker) in EncounterService.shared.activeEncounters {
            if let existing = encounterMap[profileId] {
                if tracker.totalSeconds > (existing.overlapSeconds ?? 0) {
                    encounterMap[profileId] = Encounter(
                        id: existing.id,
                        eventId: existing.eventId,
                        profileA: existing.profileA,
                        profileB: existing.profileB,
                        firstSeenAt: tracker.firstSeen,
                        lastSeenAt: tracker.lastSeen,
                        overlapSeconds: tracker.totalSeconds,
                        confidence: min(1.0, Double(tracker.totalSeconds) / 300.0)
                    )
                }
            } else {
                // Not in DB yet (below flush threshold or not flushed yet)
                encounterMap[profileId] = Encounter(
                    id: UUID(),
                    eventId: eventId,
                    profileA: myId,
                    profileB: profileId,
                    firstSeenAt: tracker.firstSeen,
                    lastSeenAt: tracker.lastSeen,
                    overlapSeconds: tracker.totalSeconds,
                    confidence: min(1.0, Double(tracker.totalSeconds) / 300.0)
                )
            }
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
                insight: profileInsight,
                decision: nil // populated below
            ))
        }

        // Run Decision Engine on all candidates
        DecisionEngine.shared.resetSession()
        let candidates = ranked.map { profile -> DecisionCandidate in
            let enc = encounterMap[profile.profileId]
            let msgTime = lastMessageTime[profile.profileId]
            let signal = signals.first(where: { $0.profileId == profile.profileId })

            // candidateIsActive: use 5-min window (matches activeWindow in EventAttendeesService)
            // v1 used isActiveNow (60s) which was too strict — most attendees appeared inactive
            // between heartbeat ticks.
            let attendee = attendees.first(where: { $0.id == profile.profileId })
            let candidateActive: Bool
            if let a = attendee {
                candidateActive = Date().timeIntervalSince(a.lastSeen) < 300
            } else {
                candidateActive = false
            }

            // encounterCount: use the in-memory tracker count if available (more accurate
            // than the DB which has a unique constraint per pair per event = always 0 or 1).
            let trackerCount = EncounterService.shared.activeEncounters[profile.profileId] != nil ? 1 : 0
            let dbCount = signal?.encounterCount ?? (enc != nil ? 1 : 0)
            let effectiveEncounterCount = max(dbCount, trackerCount)

            return DecisionCandidate(
                profileId: profile.profileId,
                name: profile.name,
                totalEncounterSeconds: enc?.overlapSeconds ?? 0,
                encounterCount: effectiveEncounterCount,
                isConnected: profile.isConnected,
                hasRecentMessage: profile.hasMessaged && (msgTime.map { Date().timeIntervalSince($0) < 600 } ?? false),
                lastMessageAge: msgTime.map { Date().timeIntervalSince($0) },
                lastSeenAge: profile.lastInteractionAt.map { Date().timeIntervalSince($0) },
                sharedInterests: signal?.sharedInterests ?? [],
                viewerInterests: signal?.viewerInterests ?? [],
                theirInterests: signal?.theirInterests ?? [],
                viewerIsActive: true,
                candidateIsActive: candidateActive
            )
        }

        let decisions = DecisionEngine.shared.evaluate(candidates: candidates, totalAttendees: attendees.count)
        let decisionMap = Dictionary(uniqueKeysWithValues: decisions.map { ($0.profileId, $0) })

        // Attach decisions and re-sort: profiles with decisions first (by tier), then by score
        let finalRanked = ranked.map { profile -> RankedProfile in
            RankedProfile(
                profileId: profile.profileId,
                name: profile.name,
                score: profile.score,
                encounterStrength: profile.encounterStrength,
                isConnected: profile.isConnected,
                hasMessaged: profile.hasMessaged,
                lastInteractionAt: profile.lastInteractionAt,
                insight: profile.insight,
                decision: decisionMap[profile.profileId]
            )
        }

        // Decision-bearing profiles first (sorted by tier), then remaining by score
        let withDecision = finalRanked.filter { $0.decision != nil }.sorted { ($0.decision?.tier ?? .followUpGap) < ($1.decision?.tier ?? .followUpGap) }
        let withoutDecision = finalRanked.filter { $0.decision == nil }.sorted { $0.score > $1.score }

        return (withDecision + withoutDecision)
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
    let decision: SurfaceDecision?
}
