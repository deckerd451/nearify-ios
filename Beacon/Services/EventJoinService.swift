import Foundation
import Combine
import Supabase

@MainActor
final class EventJoinService: ObservableObject {

    static let shared = EventJoinService()

    // MARK: - Published State

    @Published private(set) var currentEventID: String?
    @Published private(set) var currentEventName: String?
    @Published private(set) var isEventJoined: Bool = false
    @Published private(set) var isCheckedIn: Bool = false
    @Published private(set) var joinError: String?

    /// Canonical membership state — the single source of truth for the UI.
    @Published private(set) var membershipState: EventMembershipState = .notInEvent

    /// Post-event summary generated when leaving or entering dormant state.
    /// Cleared on next event join.
    @Published private(set) var postEventSummary: PostEventSummary?

    /// Local timestamp for the currently active check-in session.
    /// Used to scope post-event summaries to the session that just ended.
    @Published private(set) var activeSessionStartedAt: Date?
    @Published private(set) var userIntent: UserIntent = .none

    enum UserIntent: Equatable {
        case none
        case navigateToEvent
    }

    // MARK: - Multi-Join State
    //
    // Users may RSVP to multiple events simultaneously.
    // joinedEventIDs tracks all events the user has joined (RSVPd).
    // currentEventID is the checked-in event, or the most recently joined
    // event when not checked in.

    /// All events the user has joined (RSVP'd). May contain multiple entries.
    @Published private(set) var joinedEventIDs: Set<String> = []
    /// Maps eventID → eventName for all joined events.
    @Published private(set) var joinedEventNames: [String: String] = [:]

    /// Singular social context the user is actively inhabiting right now.
    /// This is intentionally stricter than joined membership:
    /// - joinedEventIDs = "I may attend these"
    /// - activeSocialContextEventID = "I am socially here now"
    var activeSocialContextEventID: String? {
        guard isCheckedIn else { return nil }
        return currentEventID
    }

    var activeSocialContextEventName: String? {
        guard isCheckedIn else { return nil }
        return currentEventName
    }

    // MARK: - Check-In Switch Confirmation
    //
    // A check-in conflict arises only when the user tries to CHECK IN to
    // Event B while already checked in to Event A.
    // Joining an additional event (RSVP) is always allowed without confirmation.

    struct PendingCheckInSwitch: Equatable {
        let currentCheckedInEventName: String
        let targetEventId: String
        let targetEventName: String?
    }

    @Published var pendingCheckInSwitch: PendingCheckInSwitch?

    private let supabase = AppEnvironment.shared.supabaseClient
    private let presence = EventPresenceService.shared
    private let beaconPresence = BeaconPresenceService.shared

    /// Subscription for beacon zone changes — used for soft recovery.
    private var beaconCancellable: AnyCancellable?
    private var joinedProfileId: UUID?
    private var isLeaveInProgress = false
    /// Tracks the background reconciliation task so it can be cancelled on auth loss,
    /// preventing a stale-session query from wiping the persisted context mid-restoration.
    private var activeReconciliationTask: Task<Void, Never>?
    /// The Supabase auth user ID of the currently authenticated user.
    /// Seeded from CachedIdentityStore on cold launch; set authoritatively by notifyAuthenticatedUser().
    /// Used to scope persisted join contexts to the correct user.
    private var currentAuthUserId: String?
    private let minimumContactSyncInteractionScore = 1.2

    /// Timestamp when the app entered background. Used for timeout calculation.
    private(set) var backgroundEnteredAt: Date?

    /// Grace window: how long the user stays INACTIVE before entering dormant state.
    /// Dormant means the heartbeat pauses but membership is preserved.
    /// The user remains "joined" in the DB and can resume instantly.
    /// 3 minutes matches the spec — short enough to pause heartbeat for battery,
    /// long enough to cover brief app switches and notification checks.
    let dormancyThreshold: TimeInterval = 180.0  // 3 minutes

    // MARK: - Reconnect Recovery

    /// How long after leaving/timing out the user can reconnect without QR.
    let reconnectWindow: TimeInterval = 7200.0  // 2 hours

    /// Whether the reconnect prompt was dismissed this app session.
    @Published private(set) var reconnectDismissedThisSession = false

    /// True from init until the async backend reconciliation of persisted join state finishes.
    /// Views should hold brief presentation and live-mode surfaces until this clears.
    @Published private(set) var isRestoringFromPersist: Bool = false

    /// Last event context persisted to UserDefaults for reconnect recovery.
    struct LastEventContext: Codable {
        let eventId: String
        let eventName: String
        let timestamp: Date
    }

    private let lastEventKey = "nearify.lastEventContext"
    private let activeJoinedEventKey = "nearify.activeJoinedEventContext"
    private let restoreActiveContextWindow: TimeInterval = 90 * 60 // 90 minutes
    private let staleCheckInWindow: TimeInterval = 20 * 60 // 20 minutes

    private struct ActiveJoinedEventContext: Codable {
        let eventId: String
        let eventName: String
        let isCheckedIn: Bool
        let persistedAt: Date
        // v2: user-scoped multi-join persistence (nil in contexts written before this update)
        let authUserId: String?
        let joinedEventIDs: [String]?
        let joinedEventNames: [String: String]?
        let sessionStartedAt: Date?
    }

    /// Returns the last event context if it exists and is within the recovery window.
    /// Not available when dormant — dormant users see the Resume UI instead.
    var reconnectContext: LastEventContext? {
        guard !reconnectDismissedThisSession,
              case .notInEvent = membershipState,
              let data = UserDefaults.standard.data(forKey: lastEventKey),
              let ctx = try? JSONDecoder().decode(LastEventContext.self, from: data),
              Date().timeIntervalSince(ctx.timestamp) < reconnectWindow
        else { return nil }
        return ctx
    }

    /// Persists the current event as the last event context.
    private func saveLastEventContext(eventId: String, eventName: String) {
        let ctx = LastEventContext(eventId: eventId, eventName: eventName, timestamp: Date())
        if let data = try? JSONEncoder().encode(ctx) {
            UserDefaults.standard.set(data, forKey: lastEventKey)
            #if DEBUG
            print("[EventJoin] 💾 Saved last event context: \(eventName)")
            #endif
        }
    }

    private func persistActiveJoinedState() {
        guard let eventId = currentEventID,
              let eventName = currentEventName,
              isEventJoined else {
            // No active event to persist. Leave the existing context intact so that
            // same-user restoration can work across sign-out/sign-in cycles.
            // Explicit clearing is done only in leaveEvent() and clearPersistedJoinedState().
            return
        }

        let context = ActiveJoinedEventContext(
            eventId: eventId,
            eventName: eventName,
            isCheckedIn: isCheckedIn,
            persistedAt: Date(),
            authUserId: currentAuthUserId,
            joinedEventIDs: Array(joinedEventIDs),
            joinedEventNames: joinedEventNames,
            sessionStartedAt: activeSessionStartedAt
        )
        if let data = try? JSONEncoder().encode(context) {
            UserDefaults.standard.set(data, forKey: activeJoinedEventKey)
            #if DEBUG
            print("[EventPersistence] 💾 Saved: \"\(eventName)\", user=\(currentAuthUserId.map { String($0.prefix(8)) } ?? "unknown"), events=\(joinedEventIDs.count)")
            #endif
        }
    }

    private func restorePersistedJoinedState() {
        guard let data = UserDefaults.standard.data(forKey: activeJoinedEventKey),
              let context = try? JSONDecoder().decode(ActiveJoinedEventContext.self, from: data) else {
            return
        }

        // Cross-user protection: if we already know the current auth user and it differs,
        // block restore and clear the stale context immediately.
        // Note: notifyAuthenticatedUser() performs the definitive check once auth fully loads.
        if let persistedUser = context.authUserId,
           let knownUser = currentAuthUserId,
           persistedUser != knownUser {
            #if DEBUG
            print("[EventRestore] ⛔ Cold-launch restore blocked — user mismatch")
            print("[EventRestore]    Persisted user: \(String(persistedUser.prefix(8)))")
            print("[EventRestore]    Current user:   \(String(knownUser.prefix(8)))")
            #endif
            UserDefaults.standard.removeObject(forKey: activeJoinedEventKey)
            return
        }

        // Restore full multi-join set from snapshot; fall back to primary event for legacy contexts.
        joinedEventIDs = Set(context.joinedEventIDs ?? [context.eventId])
        joinedEventNames = context.joinedEventNames ?? [context.eventId: context.eventName]

        let shouldRestoreActiveContext = shouldRestoreActiveContext(from: context)
        if shouldRestoreActiveContext {
            currentEventID = context.eventId
            currentEventName = context.eventName
            isEventJoined = true
            isCheckedIn = false
            membershipState = .joined(eventName: context.eventName)
            activeSessionStartedAt = context.sessionStartedAt
        } else {
            // Restore joined membership passively without forcing a dominant context on Home.
            currentEventID = nil
            currentEventName = nil
            isEventJoined = !joinedEventIDs.isEmpty
            isCheckedIn = false
            membershipState = .notInEvent
            activeSessionStartedAt = nil
        }

        #if DEBUG
        print("[EventRestore] ✅ Cold-launch membership restore: \(joinedEventIDs.count) joined events")
        print("[EventRestore]    active context restored: \(shouldRestoreActiveContext ? "yes" : "no")")
        print("[EventRestore]    Auth user: \(context.authUserId.map { String($0.prefix(8)) } ?? "legacy — no user stamp")")
        print("[EventRestore]    Multi-join events: \(joinedEventIDs.count)")
        print("[EventRestore]    Session started: \(context.sessionStartedAt?.description ?? "none")")
        #endif
    }

    private func shouldRestoreActiveContext(from context: ActiveJoinedEventContext) -> Bool {
        // Passive restore is always allowed for joined memberships.
        // Active context restore is intentionally conservative.
        let age = Date().timeIntervalSince(context.persistedAt)
        guard age <= restoreActiveContextWindow else { return false }
        guard context.isCheckedIn else { return false }
        if let startedAt = context.sessionStartedAt {
            let inactiveDuration = Date().timeIntervalSince(startedAt)
            if inactiveDuration > staleCheckInWindow { return false }
        }
        return true
    }

    private func reconcilePersistedJoinedStateWithBackend() async {
        guard isEventJoined else { return }
        do {
            let profile = try await ensureProfile()
            joinedProfileId = profile.id

            // Snapshot the active event ID before any async work so fallback logic
            // is stable even if other code mutates currentEventID concurrently.
            let primaryEventId = currentEventID

            // Scope the query to only events already tracked locally.
            // Querying all rows for the profile inflates the set with historical
            // rows that were joined and never explicitly left — causing "9 events".
            let scopedIds = Array(joinedEventIDs.union(primaryEventId.map { [$0] } ?? []))
            guard !scopedIds.isEmpty else {
                guard AuthService.shared.isAuthenticated else { return }
                clearPersistedJoinedState()
                return
            }

            let rows: [NearifyAttendeeWithEvent] = try await supabase
                .from("event_attendees")
                .select("id,event_id,profile_id,status,events(id,name)")
                .eq("profile_id", value: profile.id.uuidString)
                .in("event_id", values: scopedIds)
                .in("status", values: ["joined", "inEvent"])
                .execute()
                .value

            if rows.isEmpty {
                // Only clear the persisted context when the user is authenticated and Supabase
                // has definitively confirmed no active memberships for that profile.
                // If we're not authenticated (e.g. this Task survived a sign-out), clearing
                // would destroy the context before notifyAuthenticatedUser() can restore it.
                guard AuthService.shared.isAuthenticated else {
                    #if DEBUG
                    print("[OfflineRecovery] ⚠️ Empty rows but not authenticated — preserving persisted state for same-user restoration")
                    #endif
                    return
                }
                #if DEBUG
                print("[EventRestore] ⚠️ Backend confirmed 0 active memberships — clearing persisted state")
                #endif
                clearPersistedJoinedState()
                return
            }

            // Validate the primary persisted event is still active on the backend.
            let confirmedIds = Set(rows.map { $0.event_id.uuidString })
            let primaryIsActive = primaryEventId.map { confirmedIds.contains($0) } ?? false
            if primaryIsActive {
                #if DEBUG
                print("[RestoreHydration] active event preserved: \"\(currentEventName ?? primaryEventId ?? "?")\"")
                #endif
            } else if primaryEventId != nil, let first = rows.first {
                // Primary was left server-side — fall back to next confirmed active event.
                currentEventID = first.event_id.uuidString
                currentEventName = first.eventName
                let restoredName = first.eventName?.trimmingCharacters(in: .whitespacesAndNewlines)
                membershipState = .joined(eventName: restoredName?.isEmpty == false ? restoredName! : "Event")
            } else if primaryEventId != nil {
                clearPersistedJoinedState()
                return
            }

            // Build confirmed joined set — backend-validated events only.
            // Log any locally-persisted event the backend did NOT confirm as active.
            var ids: Set<String> = []
            var names: [String: String] = [:]
            for row in rows {
                let idStr = row.event_id.uuidString
                ids.insert(idStr)
                if let name = row.eventName { names[idStr] = name }
            }
            #if DEBUG
            for staleId in joinedEventIDs.subtracting(confirmedIds) {
                print("[RestoreHydration] skipped historical joined event: \(String(staleId.prefix(8))) (not confirmed active by backend)")
            }
            #endif

            // Avoid redundant @Published emissions — only assign if values actually changed.
            // Redundant assigns trigger downstream Combine sinks (e.g. EventAttendeesService)
            // even when nothing meaningful changed.
            if ids != joinedEventIDs { joinedEventIDs = ids }
            if names != joinedEventNames { joinedEventNames = names }
            if !ids.isEmpty != isEventJoined { isEventJoined = !ids.isEmpty }

            persistActiveJoinedState()

            // Hydrate context pipeline for the confirmed active event.
            // Ensures Home/Brief/intelligence have event data even though
            // the heartbeat is not running (joined state, not checked in).
            if let eventIdStr = currentEventID, let eventUUID = UUID(uuidString: eventIdStr) {
                let eventName = currentEventName ?? "event"
                Task(priority: .utility) {
                    await EventContextService.shared.fetchContext(eventId: eventUUID)
                    #if DEBUG
                    print("[RestoreHydration] event context hydrated for \"\(eventName)\"")
                    #endif
                }
                AttendeeStateResolver.shared.refreshConnections()
                #if DEBUG
                print("[RestoreHydration] attendees refresh started")
                print("[EventMembership] reconciled joined events count: \(ids.count)")
                #endif
            } else {
                #if DEBUG
                print("[RestoreHydration] passive joined restore complete — no active social context selected")
                #endif
            }
        } catch {
            // Preserve local continuity through transient launch/network failures.
        }
    }

    private func clearPersistedJoinedState() {
        // Explicit clearing path — used when backend confirms no active memberships,
        // or when a different user's context is detected.
        UserDefaults.standard.removeObject(forKey: activeJoinedEventKey)
        currentEventID = nil
        currentEventName = nil
        isEventJoined = false
        isCheckedIn = false
        membershipState = .notInEvent
        joinedEventIDs = []
        joinedEventNames = [:]
        #if DEBUG
        print("[EventPersistence] 🗑️ Persisted join state cleared (backend confirmed no active memberships)")
        #endif
    }

    /// Dismisses the reconnect prompt for the current app session.
    func dismissReconnect() {
        reconnectDismissedThisSession = true
        #if DEBUG
        print("[EventJoin] 🚫 Reconnect dismissed for this session")
        #endif
    }

    private init() {
        // Seed auth user ID from cached identity so cross-user protection works before auth loads.
        currentAuthUserId = CachedIdentityStore.shared.authUserId
        #if DEBUG
        if let uid = currentAuthUserId {
            print("[EventPersistence] 🔑 Seeded auth user ID from cache: \(String(uid.prefix(8)))")
        } else {
            print("[EventPersistence] ℹ️ No cached auth user ID — first launch or signed out")
        }
        #endif

        // Gate the brief and live surfaces until we confirm the persisted join is still valid.
        if UserDefaults.standard.data(forKey: activeJoinedEventKey) != nil {
            isRestoringFromPersist = true
        }
        restorePersistedJoinedState()
        startBeaconRecoveryObservation()
        activeReconciliationTask = Task {
            await reconcilePersistedJoinedStateWithBackend()
            activeReconciliationTask = nil
            isRestoringFromPersist = false
            #if DEBUG
            EventParticipationStateResolver.logAudit(renderingSurface: "EventJoinService.init.restored")
            #endif
        }
    }

    // MARK: - Intent

    func setIntent(_ intent: UserIntent) {
        userIntent = intent
    }

    @discardableResult
    func consumeNavigationIntent() -> Bool {
        guard userIntent == .navigateToEvent else { return false }
        userIntent = .none
        return true
    }

    // MARK: - Beacon Soft Recovery
    //
    // When the user has a recent joined event context and beacon becomes
    // visible again after an interruption (background, signal loss), this
    // triggers a throttled presence refresh to improve session resilience.
    //
    // RULES:
    //   - Does NOT create new event joins — only refreshes existing sessions.
    //   - Does NOT auto-navigate or show UI.
    //   - Does NOT fire if user explicitly left or dismissed reconnect.
    //   - Throttled by EventPresenceService.beaconTriggeredRefresh().

    private func startBeaconRecoveryObservation() {
        beaconCancellable = beaconPresence.$currentZoneState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newZone in
                guard let self else { return }
                guard newZone == .inside else { return }

                // Only act if user has an active joined event.
                // Beacon alone never creates a join — it only reinforces one.
                guard self.isCheckedIn else { return }

                #if DEBUG
                print("[EventJoin] 📡 Beacon zone → inside while event active — triggering confidence refresh")
                #endif

                Task {
                    await self.presence.beaconTriggeredRefresh()
                }
            }
    }

    // MARK: - Join Event
    //
    // MULTI-JOIN MODEL:
    //   Users may RSVP to any number of events simultaneously.
    //   joinedEventIDs tracks all of them.
    //   A join is NEVER blocked by being joined elsewhere.
    //
    //   Check-in (active presence) is the only exclusive resource — only one
    //   event may be checked into at a time. Conflict handling lives in checkIn().

    func joinEvent(eventID: String, eventName: String? = nil) async {
        #if DEBUG
        print("[EventJoin] 🎫 Joining event: \(eventID)")
        #endif

        guard let eventUUID = UUID(uuidString: eventID) else {
            joinError = "Invalid event ID"
            return
        }

        // GUARD: Already joined this exact event — no-op.
        if joinedEventIDs.contains(eventID) {
            #if DEBUG
            print("[EventJoin] ⛔ Already joined event \(eventID) — skipping duplicate")
            #endif
            joinError = nil
            return
        }

        // If the user is currently checked in to a different event, this join is a
        // secondary RSVP — we call Supabase but do NOT change the primary event or
        // disrupt the active check-in session.
        let isPrimary = !isCheckedIn
        await performJoin(eventUUID: eventUUID, isPrimary: isPrimary)
    }

    /// Internal: performs the Supabase join and updates state.
    /// isPrimary=true  → updates currentEventID, membershipState, brief hydration.
    /// isPrimary=false → RSVP only; active check-in session is untouched.
    private func performJoin(eventUUID: UUID, isPrimary: Bool = true) async {

        do {
            let profile = try await ensureProfile()
            _ = try await joinEventRPC(eventID: eventUUID)
            let event = try await fetchEvent(eventID: eventUUID)

            // Register in multi-join tracking (always).
            joinedEventIDs.insert(event.id.uuidString)
            joinedEventNames[event.id.uuidString] = event.name
            joinedProfileId = profile.id
            isEventJoined = true
            joinError = nil

            #if DEBUG
            print("[EventMembership] joined event added: \(event.name)")
            print("[EventMembership] joined events count: \(joinedEventIDs.count)")
            #endif

            if isPrimary {
                // Primary join — update the active event context.
                currentEventID = event.id.uuidString
                currentEventName = event.name
                isCheckedIn = false
                membershipState = .joined(eventName: event.name)
                backgroundEnteredAt = nil
                activeSessionStartedAt = nil
                reconnectDismissedThisSession = false
                postEventSummary = nil
                persistActiveJoinedState()
                saveLastEventContext(eventId: event.id.uuidString, eventName: event.name)

                // Preload event context for intelligence pipeline (fire-and-forget).
                Task(priority: .utility) {
                    await EventContextService.shared.fetchContext(eventId: event.id)
                }
                // Begin brief hydration so the brief is rich on first view.
                BriefHydrationController.shared.startHydration(eventId: event.id, eventName: event.name)

                #if DEBUG
                let presenceCtx = presence.currentContextId
                if let presenceCtx, presenceCtx != event.id {
                    print("[EventJoin] ⚠️ STATE MISMATCH: presence contextId=\(presenceCtx) != event.id=\(event.id)")
                }
                EventParticipationStateResolver.logAudit(renderingSurface: "EventJoinService.performJoin.primary")
                print("[EventJoin] ✅ Joined event (ready for check-in): \(event.name)")
                #endif
            } else {
                // Secondary join — RSVP without disrupting the active check-in.
                #if DEBUG
                print("[EventJoin] ✅ Secondary RSVP for \(event.name) — active check-in unchanged")
                print("[EventCheckIn] active check-in unchanged: \(currentEventName ?? "none")")
                #endif
            }

        } catch {
            joinError = error.localizedDescription
            print("[EventJoin] ❌ Join failed: \(error)")
        }
    }

    // MARK: - Check-In Switch Confirmation

    /// Called when user confirms "Check in here instead" after a check-in conflict.
    func confirmCheckInSwitch() async {
        guard let pending = pendingCheckInSwitch else { return }
        pendingCheckInSwitch = nil

        #if DEBUG
        print("[EventCheckIn] switching check-in from \(currentEventName ?? "?") to \(pending.targetEventName ?? pending.targetEventId)")
        #endif

        // End the current active session without fully leaving the event (keep RSVP).
        await endActiveCheckIn()
        // Now check in to the target event.
        await performCheckIn(targetEventID: pending.targetEventId)
    }

    /// Called when user cancels the check-in switch dialog.
    func cancelCheckInSwitch() {
        pendingCheckInSwitch = nil
    }

    /// Stops the active check-in session (writes status back to "joined")
    /// without removing the event from joinedEventIDs.
    private func endActiveCheckIn() async {
        guard isCheckedIn else { return }

        _ = await presence.leaveCurrentEvent()
        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()
        beaconPresence.reset()
        LocalEncounterStore.shared.stopCapture()
        await EncounterService.shared.flushEncounters()
        EncounterService.shared.stopPeriodicFlush()

        isCheckedIn = false
        activeSessionStartedAt = nil
        if let name = currentEventName {
            membershipState = .joined(eventName: name)
        }
    }

    // MARK: - Check In

    /// Check in to an event. Pass targetEventID to check in to a specific joined event;
    /// omit to check in to currentEventID (the primary joined event).
    ///
    /// If the user is already checked in to a different event, a PendingCheckInSwitch
    /// is set so the UI can show "Check in here instead?" confirmation.
    func checkIn(targetEventID: String? = nil) async {
        let targetID = targetEventID ?? currentEventID
        guard let targetID else { return }

        // Must be joined to the target event.
        guard joinedEventIDs.contains(targetID) || (!isCheckedIn && currentEventID == targetID) else {
            joinError = "Not joined to this event"
            return
        }

        // Already checked in to this event — no-op.
        if isCheckedIn && currentEventID == targetID { return }

        // Already checked in to a DIFFERENT event — surface conflict.
        if isCheckedIn, let currentName = currentEventName, currentEventID != targetID {
            let targetName = joinedEventNames[targetID]
            pendingCheckInSwitch = PendingCheckInSwitch(
                currentCheckedInEventName: currentName,
                targetEventId: targetID,
                targetEventName: targetName
            )
            #if DEBUG
            print("[EventCheckIn] check-in conflict: checked in to \(currentName), target=\(targetName ?? targetID)")
            #endif
            return
        }

        await performCheckIn(targetEventID: targetID)
    }

    /// Internal: performs the actual check-in after all guards have passed.
    private func performCheckIn(targetEventID: String) async {
        guard let eventId = UUID(uuidString: targetEventID) else { return }
        let eventName = joinedEventNames[targetEventID] ?? currentEventName ?? "event"

        do {
            let profileId: UUID
            if let joinedProfileId {
                profileId = joinedProfileId
            } else {
                profileId = try await ensureProfile().id
                joinedProfileId = profileId
            }

            let didActivate = presence.activateFromCheckIn(
                eventName: eventName,
                contextId: eventId,
                communityId: profileId
            )
            guard didActivate else { return }

            // Promote this event to the primary slot.
            currentEventID = targetEventID
            currentEventName = eventName

            BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
            BLEScannerService.shared.startScanning()
            EncounterService.shared.startPeriodicFlush()
            LocalEncounterStore.shared.startCapture()

            isCheckedIn = true
            isEventJoined = true
            if activeSessionStartedAt == nil {
                activeSessionStartedAt = Date()
            }
            membershipState = .inEvent(eventName: eventName)
            joinError = nil
            persistActiveJoinedState()

            BriefHydrationController.shared.stopHydration()

            #if DEBUG
            EventParticipationStateResolver.logAudit(renderingSurface: "EventJoinService.checkIn")
            #endif
        } catch {
            joinError = error.localizedDescription
            print("[EventJoin] ❌ Check-in failed: \(error)")
        }
    }

    // MARK: - Leave Event (explicit user action)

    @discardableResult
    func leaveEvent(source: String = "system") async -> Bool {
        guard !isLeaveInProgress else {
            #if DEBUG
            print("[LeaveEvent] duplicate leave ignored — already in progress")
            #endif
            return false
        }
        isLeaveInProgress = true
        defer { isLeaveInProgress = false }

        let eventName = currentEventName ?? "event"
        let eventId = currentEventID ?? ""
        let eventUUID = currentEventID.flatMap(UUID.init(uuidString:))
        let sessionStartedAt = activeSessionStartedAt
        let encounterSnapshot = EncounterService.shared.activeEncounters

        #if DEBUG
        print("[LeaveEvent] started for \(eventName) (source: \(source))")
        #endif

        SocialStateResolver.shared.invalidateSocialContinuity(reason: "leaveEvent triggered (source: \(source))")
        #if DEBUG
        print("[LifecycleInvalidation] explicit leaveEvent requested")
        #endif

        // Persist for reconnect recovery before clearing state
        if !eventId.isEmpty {
            saveLastEventContext(eventId: eventId, eventName: eventName)
        }

        let didMarkLeft: Bool
        // Write status="left" to DB before clearing local state
        if isCheckedIn {
            didMarkLeft = await presence.leaveCurrentEvent()
        } else if let eventUUID = currentEventID.flatMap(UUID.init(uuidString:)),
                  let profileId = joinedProfileId {
            didMarkLeft = await presence.markLeftWithoutActiveSession(eventId: eventUUID, profileId: profileId)
        } else {
            didMarkLeft = true
        }

        guard didMarkLeft else {
            joinError = "Couldn't leave \(eventName). Check your connection and try again."
            #if DEBUG
            print("[LeaveEvent] ❌ Aborting local clear because backend leave failed")
            #endif
            return false
        }

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()
        beaconPresence.reset()

        // Stop local encounter capture before summary generation so final fragments are closed.
        LocalEncounterStore.shared.stopCapture()

        // Flush remaining encounters before leaving.
        await EncounterService.shared.flushEncounters()
        EncounterService.shared.stopPeriodicFlush()

        // Stabilization step: allow backend-driven connection graph to catch up once.
        AttendeeStateResolver.shared.refreshConnections()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Generate post-event summary AFTER stabilization but BEFORE clearing state.
        postEventSummary = PostEventSummaryBuilder.build(
            eventName: eventName,
            eventId: eventUUID,
            sessionStartedAt: sessionStartedAt,
            sessionEncounters: encounterSnapshot
        )

        print("[ContactSync] automatic sync disabled — waiting for user initiated Save to Contacts")

        // Upload encounter fragments to backend (fire-and-forget)
        LocalEncounterStore.shared.uploadPendingFragments()

        // Clear session trackers only after summary generation has consumed snapshot state.
        EncounterService.shared.clearActiveEncounters()

        // Remove the departing event from multi-join tracking.
        if let leavingID = currentEventID {
            joinedEventIDs.remove(leavingID)
            joinedEventNames.removeValue(forKey: leavingID)
        }

        // If the user is still joined to other events, promote the next one.
        // Otherwise clear everything.
        if let nextID = joinedEventIDs.first,
           let nextName = joinedEventNames[nextID] {
            currentEventID = nextID
            currentEventName = nextName
            isEventJoined = true
            isCheckedIn = false
            activeSessionStartedAt = nil
            backgroundEnteredAt = nil
            membershipState = .left(eventName: eventName)
            pendingCheckInSwitch = nil
        } else {
            currentEventID = nil
            currentEventName = nil
            joinedProfileId = nil
            isEventJoined = false
            isCheckedIn = false
            activeSessionStartedAt = nil
            backgroundEnteredAt = nil
            membershipState = .left(eventName: eventName)
            pendingCheckInSwitch = nil
        }

        EventContextService.shared.clearCache()
        // Explicit leave — permanently clear the persisted join context.
        // This is the ONLY path that destroys continuity. Temporary disconnects,
        // sign-outs, and auth refreshes do NOT reach this line.
        UserDefaults.standard.removeObject(forKey: activeJoinedEventKey)

        #if DEBUG
        print("[LeaveEvent] state cleared — isEventJoined=false, membership=left")
        print("[JoinState] 🗑️ Persisted join context cleared — explicit user leave")
        EventParticipationStateResolver.logAudit(renderingSurface: "EventJoinService.leaveEvent")
        #endif
        return true
    }

    // MARK: - Post-event Contact Sync Integration

    private struct ContactSyncCandidate {
        let profileId: UUID
        let name: String
        let confirmedConnection: Bool
        let interactionCount: Int
        let proximityDuration: Int
        let signalScore: Double
        let interactionSummary: String
        let intentAlignment: Double
        let skipReason: String?
    }

    private func contactSyncContext(for source: String) -> ContactSyncContext {
        let normalized = source.lowercased()

        if normalized.contains("wrap") {
            return .eventWrapUp
        }
        if normalized.contains("arrived") {
            return .arrived
        }
        if normalized.contains("found") {
            return .foundEachOther
        }
        if normalized.contains("proximity") {
            return .proximityDetection
        }
        if normalized.contains("ble") {
            return .bleMatch
        }
        if normalized.contains("connection") {
            return .connectionState
        }
        if normalized.contains("user") {
            return .userExplicitAction
        }
        return .unknown(source)
    }

    private func runPostEventContactSync(
        eventId: UUID?,
        eventName: String,
        eventDate: Date,
        sessionEncounters: [UUID: EncounterTracker]
    ) async {
        print("[ContactSync] evaluating contact sync")

        guard let eventId else {
            print("[ContactSync] skipped — no eligible confirmed interaction")
            return
        }

        let relationships = RelationshipMemoryService.shared.relationships
        let relationshipById = Dictionary(uniqueKeysWithValues: relationships.map { ($0.profileId, $0) })
        let localEncounters = LocalEncounterStore.shared.encounters(forEvent: eventId)
        let localByProfile = Dictionary(grouping: localEncounters.compactMap { encounter -> (UUID, LocalEncounterStore.CapturedEncounter)? in
            guard let id = encounter.resolvedProfileId else { return nil }
            return (id, encounter)
        }, by: { $0.0 }).mapValues { pairs in pairs.map(\.1) }
        let connectedIds = AttendeeStateResolver.shared.connectedIds

        var candidateIds = Set(sessionEncounters.keys)
        candidateIds.formUnion(localByProfile.keys)
        candidateIds.formUnion(
            relationships
                .filter { $0.connectionStatus == .accepted || $0.totalOverlapSeconds > 0 || $0.encounterCount > 0 }
                .map(\.profileId)
        )

        let candidates = candidateIds.compactMap { id in
            buildContactSyncCandidate(
                profileId: id,
                relationship: relationshipById[id],
                localEncounters: localByProfile[id] ?? [],
                sessionEncounter: sessionEncounters[id],
                connectedIds: connectedIds,
                eventName: eventName
            )
        }.sorted { $0.signalScore > $1.signalScore }

        guard !candidates.isEmpty else {
            print("[ContactSync] skipped — no eligible confirmed interaction")
            return
        }

        var savedAny = false
        var eligibleCount = 0

        for candidate in candidates {
            print("[ContactSync] candidate=\(candidate.name), profileId=\(candidate.profileId.uuidString), event=\(eventName)")
            let durationLog = candidate.proximityDuration > 0 ? "\(candidate.proximityDuration)" : "0"
            print("[ContactSync] confirmedConnection=\(candidate.confirmedConnection), interactionCount=\(candidate.interactionCount), proximityDuration=\(durationLog)")

            if let reason = candidate.skipReason {
                print("[ContactSync] decision=skipped, reason=\(reason)")
                continue
            }

            print("[ContactSync] decision=will sync, reason=qualified interaction score and evidence")
            eligibleCount += 1
            let payload = ContactSyncPayload(
                profileId: candidate.profileId,
                name: candidate.name,
                phoneNumber: nil,
                email: nil,
                eventId: eventId,
                eventName: eventName,
                eventDate: eventDate,
                interactionSummary: candidate.interactionSummary,
                signalScore: candidate.signalScore,
                interactionCount: candidate.interactionCount,
                intentAlignment: candidate.intentAlignment
            )

            let didSave = await ContactSyncService.shared.createOrUpdateContact(payload: payload)
            if didSave {
                savedAny = true
            }
        }

        if eligibleCount == 0 {
            print("[ContactSync] skipped — no eligible confirmed interaction")
        } else if !savedAny {
            print("[ContactSync] decision=skipped, reason=eligible candidate sync attempt failed")
        }
    }

    private func buildContactSyncCandidate(
        profileId: UUID,
        relationship: RelationshipMemory?,
        localEncounters: [LocalEncounterStore.CapturedEncounter],
        sessionEncounter: EncounterTracker?,
        connectedIds: Set<UUID>,
        eventName: String
    ) -> ContactSyncCandidate? {
        let strongestRSSI = localEncounters.map(\.signalStrengthSummary.strongestRSSI).max()
        let proximityDuration = localEncounters.map(\.duration).reduce(0, +)
        let overlapSeconds = max(sessionEncounter?.totalSeconds ?? 0, relationship?.totalOverlapSeconds ?? 0)
        let interactionCount = max(
            localEncounters.count,
            max(sessionEncounter == nil ? 0 : 1, relationship?.encounterCount ?? 0)
        )
        let confirmedConnection = connectedIds.contains(profileId) || relationship?.connectionStatus == .accepted
        let hasConversation = relationship?.hasConversation ?? false

        guard relationship != nil || sessionEncounter != nil || !localEncounters.isEmpty else {
            return nil
        }

        let name = relationship?.name
            ?? ProfileCache.shared.profile(for: profileId)?.name
            ?? "Unknown"

        let signals = InteractionScorer.Signals(
            isBLEDetected: strongestRSSI != nil,
            isHeartbeatLive: false,
            encounterSeconds: sessionEncounter?.totalSeconds ?? proximityDuration,
            historicalOverlapSeconds: relationship?.totalOverlapSeconds ?? overlapSeconds,
            lastSeenAt: sessionEncounter?.lastSeen ?? relationship?.lastEncounterAt,
            encounterCount: interactionCount,
            isConnected: confirmedConnection,
            hasConversation: hasConversation,
            sharedInterestCount: relationship?.sharedInterests.count ?? 0
        )
        let signalScore = InteractionScorer.score(signals) * 2.0
        let hasQualifiedInteractionEvidence =
            confirmedConnection ||
            hasConversation ||
            overlapSeconds >= 120 ||
            interactionCount >= 2
        let passesInteractionScoreGuard = signalScore >= minimumContactSyncInteractionScore

        let skipReason: String?
        if !hasQualifiedInteractionEvidence {
            skipReason = "insufficient interaction evidence (proximity-only)"
        } else if !passesInteractionScoreGuard {
            skipReason = "interaction score below threshold"
        } else {
            skipReason = nil
        }

        let summary: String = {
            if let rel = relationship, !rel.whyLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rel.whyLine
            }
            if proximityDuration >= 30 {
                return "Strong BLE proximity at \(eventName) (\(proximityDuration)s)"
            }
            if overlapSeconds >= 30 {
                return "Sustained overlap at \(eventName) (\(overlapSeconds)s)"
            }
            return "Met at \(eventName)"
        }()

        let intentAlignment = relationship?.relationshipStrength ?? min(signalScore / 2.0, 1.0)

        return ContactSyncCandidate(
            profileId: profileId,
            name: name,
            confirmedConnection: confirmedConnection,
            interactionCount: interactionCount,
            proximityDuration: proximityDuration,
            signalScore: signalScore,
            interactionSummary: summary,
            intentAlignment: intentAlignment,
            skipReason: skipReason
        )
    }

    // MARK: - Dormant State (inactivity without leaving)
    //
    // When the app has been inactive beyond the dormancy threshold,
    // the heartbeat pauses but membership is PRESERVED.
    // The user remains status="joined" in event_attendees.
    // They can resume instantly without re-joining.
    //
    // CRITICAL: This does NOT write status="left" to the DB.
    // Only an explicit leaveEvent() call does that.

    func enterDormant() {
        guard isCheckedIn else { return }
        guard let name = currentEventName else { return }

        // Generate post-event summary while encounter data is still available
        let encounters = EncounterService.shared.activeEncounters
        postEventSummary = PostEventSummaryBuilder.build(
            eventName: name,
            eventId: currentEventID.flatMap(UUID.init(uuidString:)),
            sessionStartedAt: activeSessionStartedAt,
            sessionEncounters: encounters
        )

        // Pause heartbeat — stop writing last_seen_at.
        // But do NOT clear event context or write "left" to DB.
        presence.stopHeartbeatOnly()

        // Stop BLE to save battery while dormant
        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()

        // Membership preserved — user is still "joined" in DB
        membershipState = .dormant(eventName: name)

        #if DEBUG
        print("[EventJoin] 💤 Entered DORMANT state — membership preserved, heartbeat paused")
        print("[EventJoin]    Event: \(name)")
        print("[EventJoin]    DB status remains: joined")
        #endif
    }

    /// Resumes an active session from dormant state.
    /// Restarts heartbeat, BLE, and restores active membership.
    func resumeFromDormant() async {
        guard case .dormant(let name) = membershipState else {
            #if DEBUG
            print("[EventJoin] ⚠️ resumeFromDormant called but not dormant")
            #endif
            return
        }

        guard let eventId = _dormantEventId ?? currentEventID.flatMap({ UUID(uuidString: $0) }),
              let profileId = _dormantProfileId ?? presence.currentCommunityId else {
            #if DEBUG
            print("[EventJoin] ⚠️ Cannot resume — missing event/profile IDs")
            #endif
            return
        }

        membershipState = .inEvent(eventName: name)
        isCheckedIn = true
        if activeSessionStartedAt == nil {
            activeSessionStartedAt = Date()
        }
        backgroundEnteredAt = nil
        persistActiveJoinedState()

        // Restart heartbeat — this writes status="joined" + fresh last_seen_at
        let didActivate = presence.activateFromCheckIn(
            eventName: name,
            contextId: eventId,
            communityId: profileId
        )
        guard didActivate else { return }

        // Restart BLE
        BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
        BLEScannerService.shared.startScanning()

        #if DEBUG
        print("[EventJoin] ✅ Resumed from DORMANT → ACTIVE")
        print("[EventJoin]    Event: \(name)")
        #endif
    }

    /// IDs preserved during dormant state for resume.
    private var _dormantEventId: UUID? {
        currentEventID.flatMap { UUID(uuidString: $0) }
    }
    private var _dormantProfileId: UUID? {
        presence.currentCommunityId
    }

    // MARK: - App Lifecycle

    /// Called when the app enters background.
    func handleAppBackground() {
        guard isCheckedIn, let name = currentEventName else { return }

        backgroundEnteredAt = Date()
        membershipState = .inactive(eventName: name)

        // Heartbeat continues running (iOS gives ~30s of background time).
        // If the app is suspended, the heartbeat pauses naturally.
        // On return, handleAppForeground() checks the elapsed time.

        #if DEBUG
        print("[EventJoin] 🌙 App backgrounded — state → INACTIVE")
        #endif
    }

    /// Called when the app returns to foreground.
    func handleAppForeground() async {
        // If dormant, check if user should resume or stay dormant
        if case .dormant = membershipState {
            #if DEBUG
            print("[EventJoin] ☀️ App foregrounded while DORMANT — showing resume UI")
            #endif
            // Stay dormant — the UI will show the Resume prompt.
            // User must tap Resume or Leave explicitly.
            return
        }

        guard let bgDate = backgroundEnteredAt else { return }

        let elapsed = Date().timeIntervalSince(bgDate)
        backgroundEnteredAt = nil

        #if DEBUG
        print("[EventJoin] ☀️ App foregrounded — was background for \(Int(elapsed))s (dormancy threshold=\(Int(dormancyThreshold))s)")
        #endif

        // Beacon soft recovery: if the user exceeded the dormancy threshold
        // but is physically in the beacon zone, extend the grace period.
        let inBeaconZone = beaconPresence.isInBeaconZone

        if elapsed > dormancyThreshold && !inBeaconZone {
            // Long absence AND not in beacon zone → enter dormant (NOT leave)
            enterDormant()
        } else if elapsed > dormancyThreshold && inBeaconZone {
            // Exceeded threshold but beacon confirms physical presence.
            // Restore active session — user is clearly still at the event.
            if isCheckedIn, let name = currentEventName {
                membershipState = .inEvent(eventName: name)

                #if DEBUG
                print("[EventJoin] 📡 Beacon recovery — exceeded dormancy threshold (\(Int(elapsed))s) but beacon zone active, restoring session")
                #endif

                await presence.beaconTriggeredRefresh()

                if let profileId = presence.currentCommunityId {
                    BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
                }
                BLEScannerService.shared.startScanning()
            } else {
                // Not joined — beacon alone doesn't create a join.
                enterDormant()
            }
        } else if isCheckedIn, let name = currentEventName {
            // Within grace window → restore active membership immediately.
            membershipState = .inEvent(eventName: name)

            // Write presence immediately so other attendees see us return.
            await presence.debugWritePresenceNow()

            if inBeaconZone {
                await presence.beaconTriggeredRefresh()
            }

            if let profileId = presence.currentCommunityId {
                BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
            }
            BLEScannerService.shared.startScanning()

            #if DEBUG
            print("[EventJoin] ✅ Returned within grace window (\(Int(elapsed))s) — state → IN_EVENT\(inBeaconZone ? " (beacon reinforced)" : "")")
            #endif
        }
    }

    /// Called when the user dismisses the LEFT state banner.
    /// This only affects the Explore banner visibility — event cleanup
    /// was already completed by leaveEvent().
    func acknowledgeExit() {
        #if DEBUG
        print("[LeaveEvent] banner dismissed")
        #endif
        membershipState = .notInEvent
    }

    // MARK: - User-Scoped Persistence

    /// Stamps the current auth user ID onto the persisted join context before sign-out.
    /// This ensures the context can be matched to the same user on re-authentication,
    /// while blocking restoration for any different user who signs in next.
    private func stampCurrentAuthUserOnPersistedContext() {
        let authUserId = currentAuthUserId ?? CachedIdentityStore.shared.authUserId
        guard let authUserId,
              let data = UserDefaults.standard.data(forKey: activeJoinedEventKey),
              let existing = try? JSONDecoder().decode(ActiveJoinedEventContext.self, from: data) else {
            #if DEBUG
            print("[EventPersistence] ℹ️ No active context to stamp or no auth user ID — skipping")
            #endif
            return
        }

        // Already stamped with the same user — no write needed.
        if existing.authUserId == authUserId {
            #if DEBUG
            print("[EventPersistence] ✅ Auth user already stamped on persisted context")
            #endif
            return
        }

        let updated = ActiveJoinedEventContext(
            eventId: existing.eventId,
            eventName: existing.eventName,
            isCheckedIn: existing.isCheckedIn,
            persistedAt: existing.persistedAt,
            authUserId: authUserId,
            joinedEventIDs: existing.joinedEventIDs ?? Array(joinedEventIDs),
            joinedEventNames: existing.joinedEventNames ?? joinedEventNames,
            sessionStartedAt: existing.sessionStartedAt ?? activeSessionStartedAt
        )
        if let updatedData = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(updatedData, forKey: activeJoinedEventKey)
            #if DEBUG
            print("[EventPersistence] 🔏 Stamped auth user ID on persisted context for same-user restoration")
            print("[EventPersistence]    User: \(String(authUserId.prefix(8)))")
            print("[EventPersistence]    Event: \"\(existing.eventName)\"")
            #endif
        }
    }

    /// Called by AuthService after every successful authentication.
    ///
    /// This is the definitive user-scope validation point:
    /// - Same user returns after sign-out → restores persisted join context automatically.
    /// - Different user signs in → clears the stale context and in-memory state.
    /// - Cold launch of same session → no-op (state already loaded by init).
    func notifyAuthenticatedUser(authUserId: String) {
        currentAuthUserId = authUserId

        #if DEBUG
        print("[AuthJoinRestore] 🔑 Authenticated user notified: \(String(authUserId.prefix(8)))")
        #endif

        guard let data = UserDefaults.standard.data(forKey: activeJoinedEventKey),
              let context = try? JSONDecoder().decode(ActiveJoinedEventContext.self, from: data) else {
            #if DEBUG
            print("[AuthJoinRestore] ℹ️ No persisted join context — nothing to validate")
            #endif
            return
        }

        // CROSS-USER PROTECTION: if the persisted context belongs to a different user, clear it.
        if let persistedUser = context.authUserId, persistedUser != authUserId {
            #if DEBUG
            print("[AuthJoinRestore] ⛔ Different user detected — clearing stale join context")
            print("[AuthJoinRestore]    Persisted: \(String(persistedUser.prefix(8)))")
            print("[AuthJoinRestore]    Current:   \(String(authUserId.prefix(8)))")
            #endif
            UserDefaults.standard.removeObject(forKey: activeJoinedEventKey)
            if isEventJoined {
                // Clear any in-memory state that was seeded from the foreign context.
                currentEventID = nil
                currentEventName = nil
                joinedEventIDs = []
                joinedEventNames = [:]
                isEventJoined = false
                isCheckedIn = false
                membershipState = .notInEvent
                isRestoringFromPersist = false
            }
            return
        }

        // SAME-USER RESTORATION: context belongs to this user (or is a legacy context without a stamp).
        if !isEventJoined {
            // In-memory state was cleared (after sign-out or auth loss) — restore from disk.
            #if DEBUG
            print("[AuthJoinRestore] ✅ Restoring join state for returning user")
            print("[AuthJoinRestore]    Event: \"\(context.eventName)\"")
            print("[AuthJoinRestore]    Multi-join count: \(max(1, context.joinedEventIDs?.count ?? 1))")
            print("[AuthJoinRestore]    Session started: \(context.sessionStartedAt?.description ?? "none")")
            #endif

            currentEventID = context.eventId
            currentEventName = context.eventName
            isEventJoined = true
            isCheckedIn = false
            membershipState = .joined(eventName: context.eventName)
            activeSessionStartedAt = context.sessionStartedAt
            joinedEventIDs = Set(context.joinedEventIDs ?? [context.eventId])
            joinedEventNames = context.joinedEventNames ?? [context.eventId: context.eventName]

            // Trigger context hydration immediately so Home/Brief can show event content
            // while backend reconciliation runs in parallel.
            if let eventUUID = UUID(uuidString: context.eventId) {
                print("[RestoreHydration] restored active event: \"\(context.eventName)\"")
                BriefHydrationController.shared.startHydration(eventId: eventUUID, eventName: context.eventName)
                Task(priority: .utility) {
                    await EventContextService.shared.fetchContext(eventId: eventUUID)
                    #if DEBUG
                    print("[RestoreHydration] event context hydrated")
                    #endif
                }
            }

            // Reconcile with backend to validate the event is still active.
            // Scoped to persisted event IDs only — does not expand the set.
            isRestoringFromPersist = true
            activeReconciliationTask?.cancel()
            activeReconciliationTask = Task {
                await reconcilePersistedJoinedStateWithBackend()
                activeReconciliationTask = nil
                isRestoringFromPersist = false
                #if DEBUG
                print("[AuthJoinRestore] ✅ Backend reconciliation complete after sign-in restoration")
                #endif
            }
        } else {
            #if DEBUG
            print("[AuthJoinRestore] ℹ️ Same user, state already loaded — no restoration needed")
            #endif
        }
    }

    // MARK: - Auth Loss

    /// Called by AuthService when auth becomes invalid (sign-out or expired session).
    ///
    /// Clears all in-memory event state and stops active services.
    /// The persisted join context is intentionally PRESERVED so that the same user
    /// can have their event context restored automatically on re-authentication.
    /// A different user signing in will have the stale context cleared by notifyAuthenticatedUser().
    func stopDueToAuthLoss() {
        print("[EventJoin] 🛑 Stopping due to auth loss")

        // Cancel any in-flight reconciliation Task first so it cannot call
        // clearPersistedJoinedState() after we return and wipe the context we
        // just preserved for same-user restoration.
        activeReconciliationTask?.cancel()
        activeReconciliationTask = nil
        isRestoringFromPersist = false

        // Stamp the current user ID onto the persisted context BEFORE clearing in-memory state.
        // CachedIdentityStore still has the user data at this point (cleared after us in signOut()).
        stampCurrentAuthUserOnPersistedContext()

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()
        beaconPresence.reset()

        currentEventID = nil
        currentEventName = nil
        joinedProfileId = nil
        currentAuthUserId = nil
        isEventJoined = false
        isCheckedIn = false
        joinError = nil
        backgroundEnteredAt = nil
        membershipState = .notInEvent
        joinedEventIDs = []
        joinedEventNames = [:]
        pendingCheckInSwitch = nil
        // NOTE: activeJoinedEventKey is intentionally NOT removed from UserDefaults here.
        // It is preserved for same-user restoration on next sign-in.
        // Different-user sign-in clears it via notifyAuthenticatedUser().
        // Explicit user leave clears it via leaveEvent().

        EventContextService.shared.clearCache()

        print("[EventJoin] ✅ In-memory event state cleared (persisted context retained for same-user restoration)")
        #if DEBUG
        print("[JoinState] 💾 activeJoinedEventKey preserved — same user can restore on re-auth")
        #endif
    }

    // MARK: - Backend

    private func ensureProfile() async throws -> NearifyProfile {
        let session = try await supabase.auth.session
        let email = session.user.email ?? ""

        let params = EnsureProfileParams(
            p_name: email,
            p_email: email,
            p_avatar_url: ""
        )

        return try await supabase
            .rpc("ensure_profile", params: params)
            .execute()
            .value
    }

    private func joinEventRPC(eventID: UUID) async throws -> NearifyAttendee {
        let params = JoinEventParams(p_event_id: eventID.uuidString)

        return try await supabase
            .rpc("join_event", params: params)
            .execute()
            .value
    }

    private func fetchEvent(eventID: UUID) async throws -> NearifyEvent {
        let events: [NearifyEvent] = try await supabase
            .from("events")
            .select("id,name")
            .eq("id", value: eventID.uuidString)
            .limit(1)
            .execute()
            .value

        guard let event = events.first else {
            throw NSError(domain: "Nearify", code: 404)
        }

        return event
    }
}

// MARK: - Models

private struct EnsureProfileParams: Encodable {
    let p_name: String
    let p_email: String
    let p_avatar_url: String
}

private struct JoinEventParams: Encodable {
    let p_event_id: String
}

private struct NearifyAttendee: Decodable {
    let id: UUID
    let event_id: UUID
    let profile_id: UUID
    let status: String
}

private struct NearifyEvent: Decodable {
    let id: UUID
    let name: String
}

private struct NearifyAttendeeWithEvent: Decodable {
    let id: UUID
    let event_id: UUID
    let profile_id: UUID
    let status: String
    private let events: EventStub?

    struct EventStub: Decodable {
        let id: UUID
        let name: String
    }

    var eventName: String? { events?.name }
}
