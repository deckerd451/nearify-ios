import Foundation
import Combine
import Supabase

// MARK: - Supabase Row Types

struct EventAttendanceRow: Codable, Identifiable {
    let id: UUID
    let eventId: UUID
    let profileId: UUID
    let status: String
    let joinedAt: Date
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case profileId = "profile_id"
        case status
        case joinedAt = "joined_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct NearifyProfileRow: Decodable {
    let id: UUID
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
    }
}

// MARK: - Event Presence Service
//
// SINGLE HEARTBEAT OWNER for the entire app.
// Writes status="joined" + last_seen_at every 25 seconds.
// No other service should run a competing heartbeat loop.
//
// BEACON INTEGRATION (enhancement-only):
//   When BeaconPresenceService reports the user is in the beacon zone,
//   the heartbeat may perform a bonus confidence refresh between normal
//   ticks. This is throttled to avoid spamming writes.
//   Beacon state NEVER starts or stops the heartbeat — only QR join does that.

@MainActor
final class EventPresenceService: ObservableObject {

    enum PresenceActivationIntent: String {
        case none
        case userCheckIn
        case explicitQR
    }

    static let shared = EventPresenceService()

    @Published private(set) var currentEvent: String?
    @Published private(set) var isWritingPresence = false
    @Published private(set) var lastPresenceWrite: Date?
    @Published private(set) var debugStatus: String = "Idle"

    /// Whether the last heartbeat tick was beacon-reinforced.
    /// Exposed for diagnostics only — does not affect event participation.
    @Published private(set) var isBeaconReinforced: Bool = false

    // Exposed for other services/views
    var currentContextId: UUID? { _currentEventId }
    var currentCommunityId: UUID? { _currentProfileId }

    private let supabase = AppEnvironment.shared.supabaseClient
    private let beaconPresence = BeaconPresenceService.shared

    private var heartbeatTask: Task<Void, Never>?
    private var _currentProfileId: UUID?
    private var _currentEventId: UUID?

    private let heartbeatInterval: TimeInterval = 25.0

    /// Minimum interval between beacon-triggered bonus refreshes.
    /// Prevents aggressive writes from fluctuating beacon signal.
    private let beaconRefreshMinInterval: TimeInterval = 60.0
    private var lastBeaconRefreshAt: Date?

    /// True when context was established via QR join.
    private(set) var isQRJoinActive = false
    private(set) var activationIntent: PresenceActivationIntent = .none
    private(set) var lastActivationIntent: PresenceActivationIntent = .none

    private init() {}

    // MARK: - Public API

    func setActivationIntent(_ intent: PresenceActivationIntent) {
        activationIntent = intent
    }

    func reset() {
        DebugLog.verbose("[EventParticipation] manual reset")
        stopHeartbeat(clearContext: true)
    }

    /// Called by AuthService when auth state becomes invalid.
    func stopDueToAuthLoss() {
        DebugLog.diagnostic("[AuthLifecycle] stopping presence due to auth loss")
        stopHeartbeat(clearContext: true)
    }

    /// Called by explicit QR/deep-link flows.
    /// Starts the heartbeat for QR-activated sessions.
    @discardableResult
    func activateFromQRJoin(eventName: String, contextId eventId: UUID, communityId profileId: UUID) -> Bool {
        activate(
            eventName: eventName,
            eventId: eventId,
            profileId: profileId,
            sourceLabel: "QR join",
            statusPrefix: "QR join active",
            allowedIntent: .explicitQR
        )
    }

    /// Called by explicit Check In action from the app UI.
    /// Starts the heartbeat for manual check-in sessions.
    @discardableResult
    func activateFromCheckIn(eventName: String, contextId eventId: UUID, communityId profileId: UUID) -> Bool {
        activate(
            eventName: eventName,
            eventId: eventId,
            profileId: profileId,
            sourceLabel: "check-in",
            statusPrefix: "Checked in",
            allowedIntent: .userCheckIn
        )
    }

    @discardableResult
    private func activate(
        eventName: String,
        eventId: UUID,
        profileId: UUID,
        sourceLabel: String,
        statusPrefix: String,
        allowedIntent: PresenceActivationIntent
    ) -> Bool {
        guard activationIntent == .userCheckIn || activationIntent == .explicitQR,
              activationIntent == allowedIntent else {
            DebugLog.diagnostic("[EventParticipation] blocked presence activation without explicit intent")
            activationIntent = .none
            return false
        }

        DebugLog.diagnostic("[EventParticipation] presence activated source=\(activationIntent.rawValue) label=\(sourceLabel) event=\(eventName)")

        lastActivationIntent = activationIntent
        isQRJoinActive = true
        _currentEventId = eventId
        _currentProfileId = profileId
        currentEvent = eventName
        debugStatus = "\(statusPrefix): \(eventName)"
        lastPresenceWrite = Date()

        startHeartbeat()
        activationIntent = .none
        return true
    }

    /// Writes status="left" to DB and stops heartbeat.
    /// Called by EventJoinService.leaveEvent() and timeoutEvent().
    func leaveCurrentEvent() async -> Bool {
        guard let eventId = _currentEventId, let profileId = _currentProfileId else {
            debugStatus = "No active event to leave"
            return false
        }

        let didSetLeft = await setAttendanceStatus(
            eventId: eventId,
            profileId: profileId,
            status: "left"
        )

        if didSetLeft {
            stopHeartbeat(clearContext: true)
        }
        return didSetLeft
    }

    /// Marks a joined attendee as left even when no active heartbeat context exists.
    /// Used for "joined but not checked in" exits.
    func markLeftWithoutActiveSession(eventId: UUID, profileId: UUID) async -> Bool {
        await setAttendanceStatus(
            eventId: eventId,
            profileId: profileId,
            status: "left"
        )
    }

    func debugWritePresenceNow() async {
        guard let eventId = _currentEventId, let profileId = _currentProfileId else {
            debugStatus = "FAILED: no active event/profile"
            return
        }

        await touchAttendance(eventId: eventId, profileId: profileId)
    }

    // MARK: - Heartbeat (SINGLE OWNER)

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        guard let eventId = _currentEventId, let profileId = _currentProfileId else {
            debugStatus = "Cannot start heartbeat: missing event/profile"
            return
        }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            DebugLog.verbose("[EventParticipation] starting heartbeat eventId=\(eventId) profileId=\(profileId)")

            // Immediate first write
            await self.touchAttendance(eventId: eventId, profileId: profileId)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }

                let hasAuth = await MainActor.run { AuthService.shared.isAuthenticated }
                guard hasAuth else {
                    DebugLog.diagnostic("[AuthLifecycle] auth lost; stopping presence heartbeat")
                    break
                }

                let shouldContinue = await MainActor.run { self.isQRJoinActive }
                guard shouldContinue else {
                    DebugLog.verbose("[EventParticipation] QR join inactive; stopping heartbeat")
                    break
                }

                // Check beacon zone state for confidence reinforcement.
                // Beacon is enhancement-only: it does NOT start/stop the heartbeat.
                // It only annotates the tick with higher confidence when the user
                // is physically confirmed in the event space.
                let inZone = await MainActor.run { self.beaconPresence.isInBeaconZone }
                await MainActor.run { self.isBeaconReinforced = inZone }

                await self.touchAttendance(eventId: eventId, profileId: profileId)

                // Update encounter tracking from BLE data on each tick
                await MainActor.run {
                    EncounterService.shared.updateFromBLE()
                }
            }

            DebugLog.verbose("[EventParticipation] heartbeat loop exited")
        }
    }

    // MARK: - Beacon Confidence Refresh (throttled)
    //
    // Called by BeaconPresenceService or EventJoinService when beacon
    // reappears after an interruption. Performs a single bonus presence
    // write to immediately update last_seen_at, but only if enough time
    // has passed since the last beacon-triggered refresh.
    //
    // WHY THROTTLED: Beacon signal fluctuates. Without a minimum interval,
    // brief signal drops and recoveries would spam the database.

    func beaconTriggeredRefresh() async {
        let now = Date()

        // Throttle: at most one beacon-triggered refresh per minute.
        if let lastRefresh = lastBeaconRefreshAt,
           now.timeIntervalSince(lastRefresh) < beaconRefreshMinInterval {
            DebugLog.verbose("[EventParticipation] ⏳ Beacon refresh throttled (last: \(Int(now.timeIntervalSince(lastRefresh)))s ago)")
            return
        }

        guard let eventId = _currentEventId, let profileId = _currentProfileId else { return }
        guard isQRJoinActive else { return }

        lastBeaconRefreshAt = now
        isBeaconReinforced = true

        DebugLog.verbose("[EventParticipation] 📡 Beacon-triggered confidence refresh")

        await touchAttendance(eventId: eventId, profileId: profileId)
    }

    private func stopHeartbeat(clearContext: Bool) {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        isWritingPresence = false
        isQRJoinActive = false
        activationIntent = .none

        if clearContext {
            _currentEventId = nil
            _currentProfileId = nil
            currentEvent = nil
            lastActivationIntent = .none
            debugStatus = "Stopped"
        } else {
            debugStatus = "Heartbeat stopped"
        }
    }

    /// Pauses the heartbeat without clearing event context or writing "left" to DB.
    /// Used when entering dormant state — membership is preserved, heartbeat is paused.
    /// The event context (IDs, event name) remains intact for resume.
    func stopHeartbeatOnly() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        isWritingPresence = false
        // Keep isQRJoinActive = true so resume can restart the heartbeat.
        // Keep _currentEventId, _currentProfileId, currentEvent intact.
        debugStatus = "Heartbeat paused (dormant)"

        DebugLog.verbose("[EventParticipation] heartbeat paused contextPreserved=true eventId=\(_currentEventId?.uuidString ?? "nil") profileId=\(_currentProfileId?.uuidString ?? "nil")")
    }

    // MARK: - Presence via event_attendees

    private func touchAttendance(eventId: UUID, profileId: UUID) async {
        // Skip heartbeat writes when offline — no point hitting the network
        guard await MainActor.run(body: { NetworkMonitor.shared.isOnline }) else {
            await MainActor.run {
                DebugLog.verbose("[EventParticipation] skipping presence heartbeat while offline")
                self.debugStatus = "Nearby Mode — heartbeat paused"
            }
            return
        }

        await MainActor.run {
            isWritingPresence = true
            debugStatus = "Writing attendance heartbeat..."
        }

        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)
        DebugLog.verbose("[EventParticipation] heartbeat write profile_id=\(profileId.uuidString) event_id=\(eventId.uuidString) last_seen_at=\(nowISO)")

        do {
            let existing: [EventAttendanceRow] = try await supabase
                .from("event_attendees")
                .select("id, event_id, profile_id, status, joined_at, last_seen_at")
                .eq("event_id", value: eventId.uuidString)
                .eq("profile_id", value: profileId.uuidString)
                .limit(1)
                .execute()
                .value

            if let existingRow = existing.first {
                try await supabase
                    .from("event_attendees")
                    .update([
                        "status": AnyJSON.string("joined"),
                        "last_seen_at": AnyJSON.string(nowISO)
                    ])
                    .eq("id", value: existingRow.id.uuidString)
                    .execute()

                await MainActor.run {
                    lastPresenceWrite = now
                    debugStatus = "Heartbeat updated at \(now.formatted(date: .omitted, time: .standard))"
                }

                DebugLog.verbose("[EventParticipation] ✅ Updated event_attendees heartbeat profile_id=\(profileId.uuidString) event_id=\(eventId.uuidString) status=joined last_seen_at=\(nowISO)")
            } else {
                try await supabase
                    .from("event_attendees")
                    .insert([
                        [
                            "event_id": AnyJSON.string(eventId.uuidString),
                            "profile_id": AnyJSON.string(profileId.uuidString),
                            "status": AnyJSON.string("joined"),
                            "joined_at": AnyJSON.string(nowISO),
                            "last_seen_at": AnyJSON.string(nowISO)
                        ]
                    ])
                    .execute()

                await MainActor.run {
                    lastPresenceWrite = now
                    debugStatus = "Attendance inserted at \(now.formatted(date: .omitted, time: .standard))"
                }

                DebugLog.verbose("[EventParticipation] ✅ Inserted event_attendees row profile_id=\(profileId.uuidString) event_id=\(eventId.uuidString) status=joined last_seen_at=\(nowISO)")
            }
        } catch {
            let isCancellation: Bool
            if let nsError = error as NSError?,
               nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                isCancellation = true
            } else {
                isCancellation = false
            }

            if isCancellation {
                DebugLog.diagnostic("[EventParticipation] ⚠️ Attendance write cancelled")
                await MainActor.run { debugStatus = "Write cancelled" }
            } else {
                DebugLog.diagnostic("[EventParticipation] ❌ Attendance heartbeat failed: \(error.localizedDescription)")
                await MainActor.run { debugStatus = "FAILED write: \(error.localizedDescription)" }
            }
        }

        await MainActor.run { isWritingPresence = false }
    }

    private func setAttendanceStatus(eventId: UUID, profileId: UUID, status: String) async -> Bool {
        await MainActor.run {
            isWritingPresence = true
            debugStatus = "Updating attendance status..."
        }

        let nowISO = ISO8601DateFormatter().string(from: Date())

        do {
            try await supabase
                .from("event_attendees")
                .update([
                    "status": AnyJSON.string(status),
                    "last_seen_at": AnyJSON.string(nowISO)
                ])
                .eq("event_id", value: eventId.uuidString)
                .eq("profile_id", value: profileId.uuidString)
                .execute()

            await MainActor.run {
                lastPresenceWrite = Date()
                debugStatus = "Status set to \(status)"
            }

            DebugLog.verbose("[EventParticipation] ✅ Attendance status updated to \(status)")
            await MainActor.run { isWritingPresence = false }
            return true
        } catch {
            DebugLog.diagnostic("[EventParticipation] ❌ Failed to set attendance status: \(error.localizedDescription)")
            await MainActor.run { debugStatus = "FAILED status update: \(error.localizedDescription)" }
            await MainActor.run { isWritingPresence = false }
            return false
        }
    }

    // MARK: - Helpers

    func resolveProfileId() async -> UUID? {
        do {
            let session = try await supabase.auth.session
            let authUserId = session.user.id

            let rows: [NearifyProfileRow] = try await supabase
                .from("profiles")
                .select("id, user_id")
                .eq("user_id", value: authUserId.uuidString)
                .limit(1)
                .execute()
                .value

            return rows.first?.id
        } catch {
            DebugLog.diagnostic("[AuthLifecycle] failed to resolve profile id from auth uid: \(error)")
            return nil
        }
    }
}
