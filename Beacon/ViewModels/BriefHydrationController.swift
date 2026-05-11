import Foundation
import Combine
import Supabase

/// Manages the hydration lifecycle for the pre-event intelligence brief.
///
/// Fetches joined attendees directly from Supabase (bypassing EventAttendeesService's
/// presence gate, which requires check-in). Enriches people with RelationshipMemory.
/// Rebuilds reactively when the goal changes or relationship data updates.
///
/// Pipeline:
///   waitingForContext   → polls EventContextService.cachedContext (3s timeout)
///   loadingIntelligence → attendees + profiles fetch in flight
///   hydrated            → brief built with real people; reactive rebuilds active
@MainActor
final class BriefHydrationController: ObservableObject {

    static let shared = BriefHydrationController()

    enum BriefHydrationState: Equatable {
        case idle
        case waitingForContext
        case loadingIntelligence
        case partial
        case hydrated
        case timeoutFallback

        var loadingMessage: String? {
            switch self {
            case .waitingForContext: return "Loading event context…"
            case .loadingIntelligence: return "Building your brief…"
            default: return nil
            }
        }

        var isLoading: Bool {
            switch self {
            case .waitingForContext, .loadingIntelligence: return true
            default: return false
            }
        }
    }

    @Published private(set) var hydrationState: BriefHydrationState = .idle
    @Published private(set) var currentBrief: PreEventBriefBuilder.Brief?

    private var hydrationTask: Task<Void, Never>?
    private var rebuildDebounceTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var activeEventId: UUID?
    private var activeEventName: String?
    private var preEventAttendees: [PreEventAttendee] = []
    private var cachedGoal: String?

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Pre-event attendee model

    struct PreEventAttendee {
        let id: UUID
        let name: String
        let avatarUrl: String?
    }

    // MARK: - Public API

    /// Begin hydrating the brief for a newly joined event.
    /// Safe to call multiple times — cancels any in-flight hydration first.
    func startHydration(eventId: UUID, eventName: String) {
        stopHydration()
        activeEventId = eventId
        activeEventName = eventName
        preEventAttendees = []
        cachedGoal = nil
        currentBrief = nil
        hydrationState = .waitingForContext

        #if DEBUG
        print("[BriefHydration] startHydration — eventId=\(eventId.uuidString.prefix(8)) eventName=\"\(eventName)\"")
        #endif

        hydrationTask = Task { await runHydrationPipeline(eventId: eventId, eventName: eventName) }
    }

    /// Tear down all hydration work. Call when checked in or event left.
    func stopHydration() {
        hydrationTask?.cancel()
        hydrationTask = nil
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = nil
        cancellables.removeAll()
        if activeEventId != nil {
            #if DEBUG
            print("[BriefHydration] stopHydration")
            #endif
        }
        hydrationState = .idle
        activeEventId = nil
        activeEventName = nil
    }

    // MARK: - Pipeline

    private func runHydrationPipeline(eventId: UUID, eventName: String) async {
        // Phase 1: kick relationship memory refresh and begin concurrent fetches.
        RelationshipMemoryService.shared.requestRefresh(reason: "brief-hydration-join")

        // Fetch attendees and wait for event context concurrently.
        async let attendeesFetch: [PreEventAttendee] = fetchPreEventAttendees(eventId: eventId)
        let contextArrived = await waitForEventContext(timeout: 3.0)

        preEventAttendees = await attendeesFetch

        guard !Task.isCancelled else { return }

        #if DEBUG
        print("[BriefHydration] phase1 done — contextArrived=\(contextArrived) joinedCount=\(preEventAttendees.count)")
        print("[BriefHydration] preEventAttendeesFetched count=\(preEventAttendees.count)")
        #endif

        // Phase 2: build brief immediately from real attendee data.
        hydrationState = .loadingIntelligence
        currentBrief = buildCurrentBrief(eventId: eventId, eventName: eventName)

        guard !Task.isCancelled else { return }

        let finalBrief = buildCurrentBrief(eventId: eventId, eventName: eventName)
        currentBrief = finalBrief
        hydrationState = .hydrated

        #if DEBUG
        print("[BriefHydration] hydration complete — state=\(hydrationState) priorityPeople=\(finalBrief.priorityPeople.count)")
        #endif

        // Phase 3: keep brief live as relationships refresh and goal changes arrive.
        observeReactiveSources()
    }

    // MARK: - Polling

    private func waitForEventContext(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if EventContextService.shared.cachedContext != nil { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        return EventContextService.shared.cachedContext != nil
    }

    // MARK: - Direct attendee + profile fetch (bypasses EventAttendeesService)

    private struct JoinedAttendeeRow: Decodable {
        let profileId: UUID
        enum CodingKeys: String, CodingKey { case profileId = "profile_id" }
    }

    private struct PreEventProfileRow: Decodable {
        let id: UUID
        let name: String
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case id, name
            case avatarUrl = "avatar_url"
        }
    }

    private func fetchPreEventAttendees(eventId: UUID) async -> [PreEventAttendee] {
        do {
            let myIdString = AuthService.shared.currentUser?.id.uuidString
                ?? "00000000-0000-0000-0000-000000000000"

            let attendeeRows: [JoinedAttendeeRow] = try await supabase
                .from("event_attendees")
                .select("profile_id")
                .eq("event_id", value: eventId.uuidString)
                .neq("status", value: "left")
                .neq("profile_id", value: myIdString)
                .limit(50)
                .execute()
                .value

            guard !attendeeRows.isEmpty else { return [] }

            let profileIds = attendeeRows.map { $0.profileId.uuidString }
            let profileRows: [PreEventProfileRow] = try await supabase
                .from("profiles")
                .select("id, name, avatar_url")
                .in("id", values: profileIds)
                .execute()
                .value

            let profiles = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })
            let attendees: [PreEventAttendee] = attendeeRows.compactMap { row in
                guard let profile = profiles[row.profileId] else { return nil }
                return PreEventAttendee(id: row.profileId, name: IdentityDisplayName.primaryName(name: profile.name, email: profile.email, debugSource: "BriefHydrationController.swift"), avatarUrl: profile.avatarUrl)
            }

            #if DEBUG
            print("[BriefHydration] preEventAttendeesFetched count=\(attendees.count)")
            #endif
            return attendees
        } catch {
            #if DEBUG
            print("[BriefHydration] fetchPreEventAttendees failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    // MARK: - People builder

    private func buildPreEventPeople(goal: String) -> [PreEventBriefBuilder.PriorityPerson] {
        let relationships = RelationshipMemoryService.shared.relationships
        let goalTokens = tokenize(goal)

        // Sort: people with relationship memory first (richer reason), then alphabetically.
        let sorted = preEventAttendees.sorted { a, b in
            let aHasRel = relationships.contains { $0.profileId == a.id }
            let bHasRel = relationships.contains { $0.profileId == b.id }
            if aHasRel != bHasRel { return aHasRel }
            return a.name < b.name
        }

        let people = sorted.prefix(3).map { attendee -> PreEventBriefBuilder.PriorityPerson in
            let rel = relationships.first { $0.profileId == attendee.id }
            let reason = buildPreEventReason(relationship: rel, goalTokens: goalTokens)
            return PreEventBriefBuilder.PriorityPerson(
                id: attendee.id,
                name: IdentityDisplayName.primaryName(name: attendee.name, email: attendee.publicEmail, debugSource: "BriefHydrationController.swift"),
                avatarUrl: attendee.avatarUrl,
                statusLabel: nil,
                reason: reason,
                matchScore: nil,
                confidence: nil,
                isNearby: nil
            )
        }

        #if DEBUG
        print("[BriefHydration] preEventRecommendationsBuilt count=\(people.count)")
        #endif
        return Array(people)
    }

    private func buildPreEventReason(relationship: RelationshipMemory?, goalTokens: Set<String>) -> String {
        guard let rel = relationship else {
            return "Also attending this event"
        }
        let goalAligned = !goalTokens.isDisjoint(with: Set(rel.sharedInterests.map { $0.lowercased() }))
        if goalAligned, let topic = rel.sharedInterests.first {
            return "Overlapping interests in \(topic), aligned with your goal"
        }
        if rel.encounterCount >= 3 {
            return "You keep showing up at the same events"
        }
        let minutes = max(rel.totalOverlapSeconds / 60, 0)
        if minutes >= 5 {
            return "You've spent time together (\(minutes) min)"
        }
        if let topic = rel.sharedInterests.first {
            return "Shared interest in \(topic)"
        }
        return "Familiar face from past events"
    }

    private func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }

    // MARK: - Reactive observation

    private func observeReactiveSources() {
        cancellables.removeAll()

        RelationshipMemoryService.shared.$relationships
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleBriefRebuild(reason: "relationships-updated")
            }
            .store(in: &cancellables)

        EventContextService.shared.contextDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.handleGoalChange()
            }
            .store(in: &cancellables)
    }

    private func handleGoalChange() {
        let newGoal = EventContextService.shared.cachedContext?.intentPrimary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let oldGoal = cachedGoal ?? ""
        guard newGoal != oldGoal else { return }
        #if DEBUG
        print("[BriefHydration] goalChanged old=\"\(oldGoal)\" new=\"\(newGoal)\"")
        #endif
        cachedGoal = newGoal.isEmpty ? nil : newGoal
        scheduleBriefRebuild(reason: "goal-changed")
    }

    private func scheduleBriefRebuild(reason: String) {
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            guard let eventId = activeEventId, let eventName = activeEventName else { return }
            let rebuilt = buildCurrentBrief(eventId: eventId, eventName: eventName)
            currentBrief = rebuilt
            if case .loadingIntelligence = hydrationState { hydrationState = .hydrated }
            if case .partial = hydrationState { hydrationState = .hydrated }
            #if DEBUG
            if reason == "goal-changed" {
                print("[BriefHydration] rebuiltForGoal priorityPeople=\(rebuilt.priorityPeople.count)")
            } else {
                print("[BriefHydration] reactive rebuild — reason=\(reason) priorityPeople=\(rebuilt.priorityPeople.count)")
            }
            #endif
        }
    }

    // MARK: - Builder call

    private func buildCurrentBrief(eventId: UUID, eventName: String) -> PreEventBriefBuilder.Brief {
        let goal = EventContextService.shared.cachedContext?.intentPrimary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedGoal = goal.isEmpty
            ? "Choose your goal to tune recommendations at check-in"
            : goal
        let people = preEventAttendees.isEmpty ? nil : buildPreEventPeople(goal: resolvedGoal)
        return PreEventBriefBuilder.build(
            eventId: eventId,
            eventName: eventName,
            joinedCount: preEventAttendees.isEmpty ? nil : preEventAttendees.count,
            preEventPeople: people
        )
    }
}
