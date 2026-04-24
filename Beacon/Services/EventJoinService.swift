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
    @Published private(set) var isSwitchingEvent: Bool = false

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

    // MARK: - Event Switch Confirmation
    //
    // When the user attempts to join a different event while already in one,
    // the join is blocked and this state is set so the UI can show a confirmation.
    // The user must explicitly confirm "Leave & Join" or cancel.

    struct PendingEventSwitch: Equatable {
        let currentEventName: String
        let newEventId: String
        let newEventName: String?
    }

    @Published var pendingEventSwitch: PendingEventSwitch?

    private let supabase = AppEnvironment.shared.supabaseClient
    private let presence = EventPresenceService.shared
    private let beaconPresence = BeaconPresenceService.shared

    /// Subscription for beacon zone changes — used for soft recovery.
    private var beaconCancellable: AnyCancellable?
    private var joinedProfileId: UUID?
    private var isLeaveInProgress = false

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

    /// Last event context persisted to UserDefaults for reconnect recovery.
    struct LastEventContext: Codable {
        let eventId: String
        let eventName: String
        let timestamp: Date
    }

    private let lastEventKey = "nearify.lastEventContext"

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

    /// Dismisses the reconnect prompt for the current app session.
    func dismissReconnect() {
        reconnectDismissedThisSession = true
        #if DEBUG
        print("[EventJoin] 🚫 Reconnect dismissed for this session")
        #endif
    }

    private init() {
        startBeaconRecoveryObservation()
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
    // EVENT OWNERSHIP RULE:
    //   The user is in EXACTLY ONE event or NO event. Never multiple.
    //   Joining a different event while already in one is BLOCKED.
    //   The caller must use confirmEventSwitch() after the user confirms.

    func joinEvent(eventID: String, eventName: String? = nil) async {
        #if DEBUG
        print("[EventJoin] 🎫 Joining event: \(eventID)")
        #endif

        guard let eventUUID = UUID(uuidString: eventID) else {
            joinError = "Invalid event ID"
            return
        }

        // GUARD: Already joined this exact event — no-op.
        if isEventJoined && currentEventID == eventID {
            #if DEBUG
            print("[EventJoin] ⛔ Already in event \(eventID) — skipping duplicate join")
            #endif
            joinError = nil
            return
        }

        // GUARD: Already in a DIFFERENT event — block and request confirmation.
        // The system NEVER silently switches events.
        if isEventJoined, let currentName = currentEventName, currentEventID != eventID {
            if let pending = pendingEventSwitch, pending.newEventId == eventID {
                #if DEBUG
                print("[EventJoin] ⏳ Switch confirmation already pending for \(eventID) — ignoring duplicate join tap")
                #endif
                return
            }
            #if DEBUG
            print("[EventJoin] ⛔ Already in \(currentName) — blocking join to \(eventID)")
            print("[EventJoin]    User must confirm event switch via UI")
            #endif
            pendingEventSwitch = PendingEventSwitch(
                currentEventName: currentName,
                newEventId: eventID,
                newEventName: eventName
            )
            return
        }

        // Clean join — no active event.
        await performJoin(eventUUID: eventUUID)
    }

    /// Called by UI after user confirms "Leave & Join" in the event switch dialog.
    func confirmEventSwitch() async {
        guard let pending = pendingEventSwitch else { return }
        isSwitchingEvent = true
        defer { isSwitchingEvent = false }
        let newEventId = pending.newEventId
        pendingEventSwitch = nil

        #if DEBUG
        print("[EventJoin] ✅ User confirmed event switch → leaving current, joining \(newEventId)")
        #endif

        // Leave current event first
        let didLeaveCurrent = await leaveEvent(source: "switch-confirmation")
        guard didLeaveCurrent else {
            joinError = "Couldn't leave current event. Please try again."
            #if DEBUG
            print("[EventJoin] ❌ Event switch aborted — failed to leave current event")
            #endif
            return
        }

        // Now join the new event
        guard let eventUUID = UUID(uuidString: newEventId) else {
            joinError = "Invalid event ID"
            return
        }
        await performJoin(eventUUID: eventUUID)
        if !isEventJoined, joinError == nil {
            joinError = "Couldn't join new event."
        }
    }

    /// Called by UI when user cancels the event switch dialog.
    func cancelEventSwitch() {
        #if DEBUG
        print("[EventJoin] 🚫 User cancelled event switch")
        #endif
        pendingEventSwitch = nil
    }

    /// Internal: performs the actual join after all guards have passed.
    private func performJoin(eventUUID: UUID) async {

        do {
            let profile = try await ensureProfile()

            _ = try await joinEventRPC(eventID: eventUUID)

            let event = try await fetchEvent(eventID: eventUUID)

            currentEventID = event.id.uuidString
            currentEventName = event.name
            joinedProfileId = profile.id
            isEventJoined = true
            isCheckedIn = false
            membershipState = .joined(eventName: event.name)
            joinError = nil
            backgroundEnteredAt = nil
            activeSessionStartedAt = nil
            reconnectDismissedThisSession = false
            postEventSummary = nil // Clear previous summary

            // STATE CONSISTENCY CHECK: all event IDs must align.
            #if DEBUG
            let presenceCtx = presence.currentContextId
            if let presenceCtx, presenceCtx != event.id {
                print("[EventJoin] ⚠️ STATE MISMATCH: presence contextId=\(presenceCtx) != event.id=\(event.id)")
            }
            print("[EventJoin] 🔒 Event lock: activeEventId=\(event.id.uuidString)")
            #endif

            // Persist for reconnect recovery
            saveLastEventContext(eventId: event.id.uuidString, eventName: event.name)

            // Preload event context for intelligence pipeline (fire-and-forget)
            Task(priority: .utility) {
                await EventContextService.shared.fetchContext(eventId: event.id)
            }

            #if DEBUG
            print("[EventJoin] ✅ Joined event (ready for check-in): \(event.name)")
            #endif

        } catch {
            joinError = error.localizedDescription
            print("[EventJoin] ❌ Join failed: \(error)")
        }
    }

    // MARK: - Leave Event (explicit user action)

    func checkIn() async {
        guard isEventJoined, !isCheckedIn else { return }
        guard let eventIdString = currentEventID,
              let eventId = UUID(uuidString: eventIdString),
              let eventName = currentEventName else {
            joinError = "Missing event context"
            return
        }

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

            BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
            BLEScannerService.shared.startScanning()
            EncounterService.shared.startPeriodicFlush()
            LocalEncounterStore.shared.startCapture()

            isCheckedIn = true
            if activeSessionStartedAt == nil {
                activeSessionStartedAt = Date()
            }
            membershipState = .inEvent(eventName: eventName)
            joinError = nil
        } catch {
            joinError = error.localizedDescription
            print("[EventJoin] ❌ Check-in failed: \(error)")
        }
    }

    @discardableResult
    func leaveEvent(source: String = "user") async -> Bool {
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

        // Upload encounter fragments to backend (fire-and-forget)
        LocalEncounterStore.shared.uploadPendingFragments()

        // Clear session trackers only after summary generation has consumed snapshot state.
        EncounterService.shared.clearActiveEncounters()

        // Clear all event state atomically.
        currentEventID = nil
        currentEventName = nil
        joinedProfileId = nil
        isEventJoined = false
        isCheckedIn = false
        activeSessionStartedAt = nil
        backgroundEnteredAt = nil
        membershipState = .left(eventName: eventName)
        pendingEventSwitch = nil

        EventContextService.shared.clearCache()

        #if DEBUG
        print("[LeaveEvent] state cleared — isEventJoined=false, membership=left")
        #endif
        return true
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

    // MARK: - Auth Loss

    /// Called by AuthService when auth becomes invalid.
    func stopDueToAuthLoss() {
        print("[EventJoin] 🛑 Stopping due to auth loss")

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()
        beaconPresence.reset()

        currentEventID = nil
        currentEventName = nil
        joinedProfileId = nil
        isEventJoined = false
        isCheckedIn = false
        joinError = nil
        backgroundEnteredAt = nil
        membershipState = .notInEvent
        pendingEventSwitch = nil

        EventContextService.shared.clearCache()

        print("[EventJoin] ✅ Event state cleared due to auth loss")
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
