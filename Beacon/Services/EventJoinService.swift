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
    @Published private(set) var joinError: String?

    /// Canonical membership state — the single source of truth for the UI.
    @Published private(set) var membershipState: EventMembershipState = .notInEvent

    private let supabase = AppEnvironment.shared.supabaseClient
    private let presence = EventPresenceService.shared

    /// Timestamp when the app entered background. Used for timeout calculation.
    private(set) var backgroundEnteredAt: Date?

    /// Grace window: how long the user stays INACTIVE before timing out.
    /// At a real event, users routinely lock their device for 15–30+ minutes
    /// (during talks, meals, conversations). The timeout must be long enough
    /// that ordinary device sleep never causes an involuntary exit.
    /// 15 minutes is the minimum realistic value; 30 minutes is safer.
    let inactivityTimeout: TimeInterval = 900.0  // 15 minutes

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

    private init() {}

    // MARK: - Join Event

    func joinEvent(eventID: String) async {
        #if DEBUG
        print("[EventJoin] 🎫 Joining event: \(eventID)")
        #endif

        guard let eventUUID = UUID(uuidString: eventID) else {
            joinError = "Invalid event ID"
            return
        }

        do {
            let profile = try await ensureProfile()

            _ = try await joinEventRPC(eventID: eventUUID)

            let event = try await fetchEvent(eventID: eventUUID)

            currentEventID = event.id.uuidString
            currentEventName = event.name
            isEventJoined = true
            membershipState = .inEvent(eventName: event.name)
            joinError = nil
            backgroundEnteredAt = nil
            reconnectDismissedThisSession = false

            // Persist for reconnect recovery
            saveLastEventContext(eventId: event.id.uuidString, eventName: event.name)

            // EventPresenceService is the SINGLE heartbeat owner.
            // It writes status="joined" + last_seen_at on every tick.
            presence.activateFromQRJoin(
                eventName: event.name,
                contextId: event.id,
                communityId: profile.id
            )

            BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profile.id)
            BLEScannerService.shared.startScanning()

            // Start encounter tracking for the Social Memory Feed
            EncounterService.shared.startPeriodicFlush()

            // Preload event context for intelligence pipeline (fire-and-forget)
            Task(priority: .utility) {
                await EventContextService.shared.fetchContext(eventId: event.id)
            }

            #if DEBUG
            print("[EventJoin] ✅ Joined event: \(event.name)")
            #endif

        } catch {
            joinError = error.localizedDescription
            print("[EventJoin] ❌ Join failed: \(error)")
        }
    }

    // MARK: - Leave Event (explicit user action)

    func leaveEvent() async {
        let eventName = currentEventName ?? "event"
        let eventId = currentEventID ?? ""

        #if DEBUG
        print("[EventJoin] 👋 User leaving event: \(eventName)")
        #endif

        // Persist for reconnect recovery before clearing state
        if !eventId.isEmpty {
            saveLastEventContext(eventId: eventId, eventName: eventName)
        }

        // Write status="left" to DB before clearing local state
        await presence.leaveCurrentEvent()

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()

        // Flush remaining encounters before leaving
        Task { await EncounterService.shared.flushEncounters() }
        EncounterService.shared.stopPeriodicFlush()

        membershipState = .left(eventName: eventName)
        currentEventID = nil
        currentEventName = nil
        isEventJoined = false
        backgroundEnteredAt = nil

        EventContextService.shared.clearCache()

        print("[EventJoin] ✅ Left event: \(eventName), status=left written to DB")
    }

    // MARK: - Timeout (system-driven exit)

    func timeoutEvent() async {
        let eventName = currentEventName ?? "event"
        let eventId = currentEventID ?? ""

        #if DEBUG
        print("[EventJoin] ⏰ Timing out from event: \(eventName)")
        #endif

        // Persist for reconnect recovery before clearing state
        if !eventId.isEmpty {
            saveLastEventContext(eventId: eventId, eventName: eventName)
        }

        // Write status="left" to DB (timed-out users are treated as left server-side)
        await presence.leaveCurrentEvent()

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()

        Task { await EncounterService.shared.flushEncounters() }
        EncounterService.shared.stopPeriodicFlush()

        membershipState = .timedOut(eventName: eventName)
        currentEventID = nil
        currentEventName = nil
        isEventJoined = false
        backgroundEnteredAt = nil

        EventContextService.shared.clearCache()

        print("[EventJoin] ✅ Timed out from event: \(eventName)")
    }

    // MARK: - App Lifecycle

    /// Called when the app enters background.
    func handleAppBackground() {
        guard isEventJoined, let name = currentEventName else { return }

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
        guard let bgDate = backgroundEnteredAt else { return }

        let elapsed = Date().timeIntervalSince(bgDate)
        backgroundEnteredAt = nil

        #if DEBUG
        print("[EventJoin] ☀️ App foregrounded — was background for \(Int(elapsed))s (timeout=\(Int(inactivityTimeout))s)")
        #endif

        if elapsed > inactivityTimeout {
            // Genuinely long absence → timeout
            await timeoutEvent()
        } else if isEventJoined, let name = currentEventName {
            // Within grace window → restore active membership immediately.
            // This covers ordinary device sleep, brief app switches, etc.
            membershipState = .inEvent(eventName: name)

            // Write presence immediately so other attendees see us return.
            // Also restarts the heartbeat if iOS suspended it.
            await presence.debugWritePresenceNow()

            // Restart BLE in case iOS tore down the session during suspension.
            if let profileId = presence.currentCommunityId {
                BLEAdvertiserService.shared.startAdvertisingForEvent(communityId: profileId)
            }
            BLEScannerService.shared.startScanning()

            #if DEBUG
            print("[EventJoin] ✅ Returned within grace window (\(Int(elapsed))s) — state → IN_EVENT")
            #endif
        }
    }

    /// Called when the user dismisses the LEFT or TIMED_OUT state.
    func acknowledgeExit() {
        membershipState = .notInEvent
    }

    // MARK: - Auth Loss

    /// Called by AuthService when auth becomes invalid.
    func stopDueToAuthLoss() {
        print("[EventJoin] 🛑 Stopping due to auth loss")

        BLEAdvertiserService.shared.stopEventAdvertising()
        BLEScannerService.shared.stopScanning()

        currentEventID = nil
        currentEventName = nil
        isEventJoined = false
        joinError = nil
        backgroundEnteredAt = nil
        membershipState = .notInEvent

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
