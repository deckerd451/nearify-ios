import Foundation
import Combine

// MARK: - Meet Candidate

/// A scored candidate for the "Meet Someone New" section.
struct MeetCandidate: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let descriptor: String      // top skill or role
    let explanation: String     // 1-line reason
    let score: Double
}

// MARK: - Meet Suggestion Service

/// Scores event attendees for "Meet Someone New" suggestions.
/// Excludes the current user and already-connected users.
/// Scoring: shared_interests * 2 + complementary_skills * 3 + same_event_presence * 5
@MainActor
final class MeetSuggestionService: ObservableObject {

    static let shared = MeetSuggestionService()

    @Published private(set) var candidates: [MeetCandidate] = []

    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    private init() {
        observe()
        // Ensure connected IDs are fresh for filtering
        AttendeeStateResolver.shared.refreshConnections()
    }

    // MARK: - Observation

    private func observe() {
        // Re-score when attendees or connections change
        Publishers.CombineLatest(
            EventAttendeesService.shared.$attendees,
            AttendeeStateResolver.shared.$connectedIds
        )
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] _, _ in self?.recalculate() }
        .store(in: &cancellables)
    }

    // MARK: - Public

    func requestRefresh(reason: String) {
        #if DEBUG
        print("[MeetSuggestion] Refresh requested: \(reason)")
        #endif
        recalculate()
    }

    // MARK: - Scoring

    private func recalculate() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.score()
        }
    }

    private func score() async {
        let attendees = EventAttendeesService.shared.attendees
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        guard let currentUser = AuthService.shared.currentUser else {
            candidates = []
            return
        }

        let myId = currentUser.id
        let mySkills = Set(currentUser.skills ?? [])
        let myInterests = Set(currentUser.interests ?? [])

        // Fetch full profiles for attendees to get skills/interests
        let profileIds = attendees.map(\.id).filter { $0 != myId && !connectedIds.contains($0) }
        guard !profileIds.isEmpty else {
            candidates = []
            return
        }

        let profilesById = await ProfileService.shared.fetchProfilesByIds(profileIds)

        var scored: [MeetCandidate] = []
        let encounters = EncounterService.shared.activeEncounters

        for attendee in attendees {
            // Exclude self and connected
            guard attendee.id != myId, !connectedIds.contains(attendee.id) else { continue }

            let profile = profilesById[attendee.id]
            let theirSkills = Set(profile?.skills ?? attendee.skills ?? [])
            let theirInterests = Set(profile?.interests ?? attendee.interests ?? [])

            // Unified interaction score
            let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
            let bleDevices = BLEScannerService.shared.getFilteredDevices()
            let isBLE = bleDevices.contains { BLEAdvertiserService.parseCommunityPrefix(from: $0.name) == prefix }

            let signals = InteractionScorer.Signals(
                isBLEDetected: isBLE,
                isHeartbeatLive: attendee.isHereNow,
                encounterSeconds: encounters[attendee.id]?.totalSeconds ?? 0,
                historicalOverlapSeconds: 0,
                lastSeenAt: encounters[attendee.id]?.lastSeen ?? attendee.lastSeen,
                encounterCount: encounters[attendee.id] != nil ? 1 : 0,
                isConnected: false, // already excluded connected
                hasConversation: false,
                sharedInterestCount: myInterests.intersection(theirInterests).count
            )
            let meetScore = InteractionScorer.score(signals)

            // Build explanation
            let explanation = buildExplanation(
                myInterests: myInterests, theirInterests: theirInterests,
                mySkills: mySkills, theirSkills: theirSkills
            )

            // Descriptor: top skill or role from bio
            let descriptor = buildDescriptor(profile: profile, attendee: attendee)

            scored.append(MeetCandidate(
                id: attendee.id,
                name: attendee.name,
                avatarUrl: profile?.imageUrl ?? attendee.avatarUrl,
                descriptor: descriptor,
                explanation: explanation,
                score: meetScore
            ))
        }

        // Sort descending, pick top 2
        scored.sort { $0.score > $1.score }
        candidates = Array(scored.prefix(2))

        #if DEBUG
        print("[MeetSuggestion] Scored \(scored.count) candidates, surfacing \(candidates.count)")
        for c in candidates {
            print("[MeetSuggestion]   \(c.name) — score: \(c.score) — \(c.explanation)")
        }
        #endif
    }

    // MARK: - Helpers

    private func buildExplanation(
        myInterests: Set<String>, theirInterests: Set<String>,
        mySkills: Set<String>, theirSkills: Set<String>
    ) -> String {
        let isInside = UserPresenceStateResolver.current == .insideEvent

        let shared = myInterests.intersection(theirInterests)
        if !shared.isEmpty {
            let topics = shared.prefix(2).joined(separator: " + ")
            return isInside
                ? "You're both here and share \(topics)"
                : "You both care about \(topics)"
        }

        let complementary = theirSkills.subtracting(mySkills)
        if !complementary.isEmpty {
            return isInside
                ? "They're here now — your skills complement each other"
                : "Your skills complement each other"
        }

        if !theirInterests.isEmpty && !myInterests.isEmpty {
            let theirs = theirInterests.prefix(2).joined(separator: " + ")
            return "Similar interests in \(theirs)"
        }

        return isInside
            ? "They're here now — easiest intro"
            : "You're both here — say hello"
    }

    private func buildDescriptor(profile: User?, attendee: EventAttendee) -> String {
        if let skills = profile?.skills, let first = skills.first {
            return first
        }
        if let bio = profile?.bio ?? attendee.bio, !bio.isEmpty {
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count <= 30 ? trimmed : String(trimmed.prefix(27)) + "…"
        }
        if let interests = profile?.interests, let first = interests.first {
            return first
        }
        return "Attendee"
    }
}
