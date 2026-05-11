import Foundation
import Combine

/// Manages the hydration lifecycle for the pre-event intelligence brief.
///
/// On first join the brief opens before EventContextService, RelationshipMemoryService,
/// and PeopleIntelligenceController have populated — resulting in a sparse snapshot.
/// This controller sequences the async dependencies correctly and drives a live
/// `currentBrief` that updates as each layer arrives.
///
/// Pipeline:
///   waitingForContext  → polls EventContextService.cachedContext (3s timeout)
///   loadingIntelligence→ waits for PeopleIntelligenceController.sections (8s timeout)
///   hydrated / timeoutFallback → final brief set; reactive rebuilds continue
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
    private var preEventJoinedCount: Int?

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Public API

    /// Begin hydrating the brief for a newly joined event.
    /// Safe to call multiple times — cancels any in-flight hydration first.
    func startHydration(eventId: UUID, eventName: String) {
        stopHydration()
        activeEventId = eventId
        activeEventName = eventName
        preEventJoinedCount = nil
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
        // Phase 1: Kick supporting services immediately.
        // EventContext was already kicked as fire-and-forget in performJoin() but may not
        // have arrived yet; RelationshipMemory and Intelligence need explicit triggers.
        RelationshipMemoryService.shared.requestRefresh(reason: "brief-hydration-join")
        PeopleIntelligenceController.shared.scheduleRebuild(reason: "brief-hydration-join")

        // Fetch real joined count directly — EventAttendeesService is permanently idle
        // for pre-check-in users, so we bypass its presence gate with a raw query.
        async let joinedCountFetch: Int = fetchJoinedCount(eventId: eventId)

        let contextArrived = await waitForEventContext(timeout: 3.0)
        preEventJoinedCount = await joinedCountFetch

        guard !Task.isCancelled else { return }

        #if DEBUG
        print("[BriefHydration] phase1 done — contextArrived=\(contextArrived) joinedCount=\(preEventJoinedCount ?? 0)")
        #endif

        // Phase 2: Build a partial brief with whatever we have so far.
        hydrationState = .loadingIntelligence
        currentBrief = buildCurrentBrief(eventId: eventId, eventName: eventName)

        // Phase 3: Wait for PeopleIntelligenceController sections.
        let intelligenceArrived = await waitForIntelligence(timeout: 8.0)

        guard !Task.isCancelled else { return }

        let finalBrief = buildCurrentBrief(eventId: eventId, eventName: eventName)
        currentBrief = finalBrief
        hydrationState = intelligenceArrived ? .hydrated : .timeoutFallback

        #if DEBUG
        let peopleCount = finalBrief?.priorityPeople.count ?? 0
        print("[BriefHydration] hydration complete — state=\(hydrationState) priorityPeople=\(peopleCount) intelligenceArrived=\(intelligenceArrived)")
        #endif

        // Phase 4: Continue reactively — brief updates as new data trickles in.
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

    private func waitForIntelligence(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasIntelligence { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
        return hasIntelligence
    }

    private var hasIntelligence: Bool {
        let s = PeopleIntelligenceController.shared.sections
        return !s.hereNow.isEmpty || !s.followUp.isEmpty || !s.notHere.isEmpty
    }

    // MARK: - Direct attendee count (bypasses EventAttendeesService)

    private struct JoinedCountRow: Decodable { let id: UUID }

    private func fetchJoinedCount(eventId: UUID) async -> Int {
        do {
            // Exclude self from the count. Falls back to a nil-UUID that matches nothing
            // if current user is somehow unavailable (should not happen during join flow).
            let myIdString = AuthService.shared.currentUser?.id.uuidString
                ?? "00000000-0000-0000-0000-000000000000"
            let rows: [JoinedCountRow] = try await supabase
                .from("event_attendees")
                .select("id")
                .eq("event_id", value: eventId.uuidString)
                .neq("status", value: "left")
                .neq("profile_id", value: myIdString)
                .execute()
                .value
            #if DEBUG
            print("[BriefHydration] fetchJoinedCount=\(rows.count) event=\(eventId.uuidString.prefix(8))")
            #endif
            return rows.count
        } catch {
            #if DEBUG
            print("[BriefHydration] fetchJoinedCount failed: \(error.localizedDescription)")
            #endif
            return 0
        }
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

        PeopleIntelligenceController.shared.$sections
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleBriefRebuild(reason: "sections-updated")
            }
            .store(in: &cancellables)
    }

    private func scheduleBriefRebuild(reason: String) {
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            guard let eventId = activeEventId, let eventName = activeEventName else { return }
            let rebuilt = buildCurrentBrief(eventId: eventId, eventName: eventName)
            currentBrief = rebuilt
            switch hydrationState {
            case .loadingIntelligence, .partial:
                hydrationState = .hydrated
            default:
                break
            }
            #if DEBUG
            let count = rebuilt?.priorityPeople.count ?? 0
            print("[BriefHydration] reactive rebuild — reason=\(reason) priorityPeople=\(count)")
            #endif
        }
    }

    // MARK: - Builder call

    private func buildCurrentBrief(eventId: UUID, eventName: String) -> PreEventBriefBuilder.Brief {
        PreEventBriefBuilder.build(
            eventId: eventId,
            eventName: eventName,
            joinedCount: preEventJoinedCount
        )
    }
}
