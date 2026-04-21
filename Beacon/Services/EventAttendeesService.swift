import Foundation
import Combine
import Supabase

// MARK: - Active Attendee Model

struct EventAttendee: Identifiable, Equatable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let bio: String?
    let skills: [String]?
    let interests: [String]?
    let energy: Double
    let lastSeen: Date

    // MARK: - Event Presence State
    //
    // Derived from event_attendees heartbeat (last_seen_at).
    // "present" = heartbeat within 60s (actively writing).
    // "stale" = heartbeat within 300s (in event but may have backgrounded).
    // "absent" = heartbeat older than 300s (should not be in active list).

    enum PresenceState: String {
        case present  // heartbeat < 60s
        case stale    // heartbeat 60s–300s
        case absent   // heartbeat > 300s
    }

    var presenceState: PresenceState {
        let age = Date().timeIntervalSince(lastSeen)
        if age < 60  { return .present }
        if age < 300 { return .stale }
        return .absent
    }

    // MARK: - Findability State
    //
    // Whether this person can be navigated to via Find.
    // Requires EITHER fresh heartbeat OR recent BLE signal.
    // Checked at navigation time, not at list render time.

    enum FindabilityState: String {
        case liveSignal     // BLE device seen within 15s
        case recentlySeen   // heartbeat within 60s (no BLE required)
        case unavailable    // neither BLE nor fresh heartbeat
    }

    /// Computes findability from heartbeat age + BLE state.
    /// `hasBLESignal` should be provided by the caller from BLEScannerService.
    func findability(hasBLESignal: Bool) -> FindabilityState {
        if hasBLESignal { return .liveSignal }
        if presenceState == .present { return .recentlySeen }
        return .unavailable
    }

    var isActiveNow: Bool {
        presenceState == .present
    }

    /// Whether this attendee should be shown with "here now" language.
    /// Stricter than list membership — only for truly active heartbeats.
    var isHereNow: Bool {
        presenceState == .present
    }

    var lastSeenText: String {
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 30 {
            return "Active now"
        } else if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 300 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "Recently"
        }
    }

    var graphSubtitleText: String {
        if let skills = skills, !skills.isEmpty {
            return skills.prefix(2).joined(separator: " • ")
        }

        if let interests = interests, !interests.isEmpty {
            return interests.prefix(2).joined(separator: " • ")
        }

        if let bio = bio, !bio.isEmpty {
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 40 {
                return trimmed
            } else {
                return String(trimmed.prefix(37)) + "..."
            }
        }

        return "Attending now"
    }

    var detailSubtitleText: String {
        if let bio = bio, !bio.isEmpty {
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 60 {
                return trimmed
            } else {
                return String(trimmed.prefix(57)) + "..."
            }
        }

        if let skills = skills, !skills.isEmpty {
            return skills.prefix(3).joined(separator: " • ")
        }

        if let interests = interests, !interests.isEmpty {
            return interests.prefix(3).joined(separator: " • ")
        }

        return "Attending now"
    }

    var bioSnippet: String? {
        guard let bio = bio, !bio.isEmpty else { return nil }

        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 {
            return trimmed
        }

        return String(trimmed.prefix(117)) + "..."
    }

    var topTags: [String] {
        if let interests = interests, !interests.isEmpty {
            return Array(interests.prefix(3))
        }

        if let skills = skills, !skills.isEmpty {
            return Array(skills.prefix(3))
        }

        return []
    }

    var initials: String {
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[1].prefix(1)
            return "\(first)\(last)".uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
}

// MARK: - Event Attendees Service

@MainActor
final class EventAttendeesService: ObservableObject {

    static let shared = EventAttendeesService()

    @Published private(set) var attendees: [EventAttendee] = []
    @Published private(set) var isLoading = false
    @Published private(set) var attendeeCount: Int = 0
    @Published var debugStatus: String = "idle"

    /// Canonical live attendee count for all UI decisions.
    /// Excludes the current user. Only counts attendees where isHereNow == true.
    /// Use this instead of `attendeeCount` or manual filtering for UI branching.
    var liveOtherCount: Int {
        let myId = AuthService.shared.currentUser?.id
        return attendees.filter { $0.id != myId && $0.isHereNow }.count
    }

    private let presence = EventPresenceService.shared
    private let eventJoin = EventJoinService.shared
    private let supabase = AppEnvironment.shared.supabaseClient
    private var cancellables = Set<AnyCancellable>()

    private var refreshTask: Task<Void, Never>?
    private var presenceState: PresenceFSMState = .idle(reason: .presenceNotReady)

    private let refreshInterval: TimeInterval = 15.0
    private let activeWindow: TimeInterval = 300.0

    private var lastFetchSignature: String = ""

    // MARK: - Presence FSM

    private enum PresenceIdleReason: String {
        case presenceNotReady
        case eventUnavailable
    }

    private enum PresenceFSMState: Equatable {
        case idle(reason: PresenceIdleReason)
        case preparing(eventId: UUID, profileId: UUID, source: String)
        case active(eventId: UUID, profileId: UUID, source: String)
    }

    private struct PresenceReadiness: Equatable {
        let eventName: String?
        let isEventJoined: Bool
        let contextId: UUID?
        let profileId: UUID?
        let isOnline: Bool

        var source: String { isEventJoined ? "QR join" : "beacon" }
        var hasRequiredContext: Bool { contextId != nil && profileId != nil }
    }

    private init() {
        observePresenceState()
    }

    // MARK: - Observation

    private func observePresenceState() {
        Publishers.CombineLatest3(
            presence.$currentEvent,
            presence.$lastPresenceWrite,
            eventJoin.$isEventJoined
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] event, _, isJoined in
            guard let self else { return }

            let readiness = PresenceReadiness(
                eventName: event,
                isEventJoined: isJoined,
                contextId: self.presence.currentContextId,
                profileId: self.presence.currentCommunityId,
                isOnline: NetworkMonitor.shared.isOnline
            )

            #if DEBUG
            print("[Attendees] observePresenceState")
            print("[Attendees]   currentEvent: \(event ?? "nil")")
            print("[Attendees]   isEventJoined: \(isJoined)")
            print("[Attendees]   hasContext: \(readiness.contextId != nil)")
            print("[Attendees]   hasUser: \(readiness.profileId != nil)")
            print("[Attendees]   currentContextId: \(self.presence.currentContextId?.uuidString ?? "nil")")
            print("[Attendees]   currentProfileId: \(self.presence.currentCommunityId?.uuidString ?? "nil")")
            #endif

            self.transitionPresenceFSM(using: readiness)
        }
        .store(in: &cancellables)
    }

    // MARK: - Refresh Loop

    private func startRefreshing() {
        guard presence.currentEvent != nil else {
            #if DEBUG
            print("[Attendees] startRefreshing aborted: currentEvent is nil")
            #endif
            return
        }

        if let task = refreshTask, !task.isCancelled {
            #if DEBUG
            print("[Attendees] Refresh loop already running")
            #endif
            return
        }

        refreshTask?.cancel()

        refreshTask = Task { [weak self] in
            guard let self else { return }

            #if DEBUG
            print("[Attendees] ▶️ Starting refresh loop")
            #endif

            await self.fetchAttendees()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.fetchAttendees()
            }

            #if DEBUG
            print("[Attendees] ⏹️ Refresh loop exited")
            #endif
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        attendees = []
        attendeeCount = 0
        isLoading = false
        debugStatus = "idle"
        lastFetchSignature = ""

        #if DEBUG
        print("[Attendees] Refresh stopped and attendee list cleared")
        #endif
    }

    private func transitionPresenceFSM(using readiness: PresenceReadiness) {
        let next = reduce(from: presenceState, readiness: readiness)
        guard next != presenceState else { return }

        #if DEBUG
        print("[AttendeesFSM] \(describe(presenceState)) -> \(describe(next))")
        #endif

        presenceState = next

        switch next {
        case .idle:
            if !readiness.isOnline {
                #if DEBUG
                print("[NearbyMode] preventing attendee clear — network offline, preserving cached state")
                #endif
                injectBLEFallbackAttendees()
            } else {
                #if DEBUG
                print("[Attendees] 🔴 Presence not ready — stopping refresh")
                #endif
                stopRefreshing()
            }

        case .preparing(let eventId, let profileId, let source):
            #if DEBUG
            print("[Attendees] 🟡 Presence preparing via \(source) (eventId=\(eventId), profileId=\(profileId))")
            #endif
            // Promote to active immediately after a stable readiness snapshot.
            transitionPresenceFSM(
                using: PresenceReadiness(
                    eventName: readiness.eventName,
                    isEventJoined: readiness.isEventJoined,
                    contextId: eventId,
                    profileId: profileId,
                    isOnline: readiness.isOnline
                )
            )

        case .active(_, _, let source):
            #if DEBUG
            print("[Attendees] 🟢 Presence ready via \(source) — starting refresh")
            #endif
            startRefreshing()
        }
    }

    private func reduce(from old: PresenceFSMState, readiness: PresenceReadiness) -> PresenceFSMState {
        guard readiness.isEventJoined || readiness.eventName != nil else {
            return .idle(reason: .eventUnavailable)
        }

        guard let eventId = readiness.contextId, let profileId = readiness.profileId else {
            return .idle(reason: .presenceNotReady)
        }

        switch old {
        case .active(let oldEventId, let oldProfileId, let source):
            if oldEventId == eventId && oldProfileId == profileId {
                return .active(eventId: eventId, profileId: profileId, source: source)
            }
            return .preparing(eventId: eventId, profileId: profileId, source: readiness.source)
        case .preparing(let oldEventId, let oldProfileId, _):
            if oldEventId == eventId && oldProfileId == profileId {
                return .active(eventId: eventId, profileId: profileId, source: readiness.source)
            }
            return .preparing(eventId: eventId, profileId: profileId, source: readiness.source)
        case .idle:
            return .preparing(eventId: eventId, profileId: profileId, source: readiness.source)
        }
    }

    private func describe(_ state: PresenceFSMState) -> String {
        switch state {
        case .idle(let reason):
            return "idle(\(reason.rawValue))"
        case .preparing(let eventId, let profileId, let source):
            return "preparing(event:\(eventId.uuidString.prefix(8)), profile:\(profileId.uuidString.prefix(8)), source:\(source))"
        case .active(let eventId, let profileId, let source):
            return "active(event:\(eventId.uuidString.prefix(8)), profile:\(profileId.uuidString.prefix(8)), source:\(source))"
        }
    }

    // MARK: - Offline BLE Fallback

    private var bleFallbackCancellable: AnyCancellable?

    /// Scans BLE devices and injects minimal attendees from ProfileCache
    /// when the network is offline and the attendee list would otherwise be empty.
    /// Only activates when offline — online behavior is unchanged.
    private func injectBLEFallbackAttendees() {
        // Cancel any previous observation to avoid duplicates
        bleFallbackCancellable?.cancel()

        // Observe BLE device changes while offline
        bleFallbackCancellable = BLEScannerService.shared.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self else { return }
                // Only inject when offline — if we come back online, normal refresh takes over
                guard !NetworkMonitor.shared.isOnline else {
                    self.bleFallbackCancellable?.cancel()
                    self.bleFallbackCancellable = nil
                    return
                }

                let bcnDevices = devices.values.filter { $0.name.hasPrefix("BCN-") }
                guard !bcnDevices.isEmpty else { return }

                let cache = ProfileCache.shared
                var injected: [EventAttendee] = []

                for device in bcnDevices {
                    guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { continue }

                    // Try to resolve a profile ID from the prefix
                    if let cached = cache.profile(forPrefix: prefix) {
                        // Avoid duplicates with existing attendees
                        guard !self.attendees.contains(where: { $0.id == cached.id }) else { continue }

                        let attendee = cache.offlineAttendee(forPrefix: prefix, profileId: cached.id)
                        injected.append(attendee)

                        #if DEBUG
                        print("[NearbyMode] injecting BLE attendee: \(attendee.name) (prefix: \(prefix))")
                        #endif
                    } else {
                        // No cached profile — build a stable anonymous identity
                        // Use a deterministic UUID derived from the prefix so the same
                        // BLE device always maps to the same attendee identity.
                        let deterministicId = UUID(uuidString: "\(prefix)-0000-0000-0000-000000000000")
                            ?? UUID()
                        guard !self.attendees.contains(where: { $0.id == deterministicId }) else { continue }

                        let name = cache.displayName(forPrefix: prefix)
                        let attendee = EventAttendee(
                            id: deterministicId,
                            name: name,
                            avatarUrl: nil,
                            bio: nil,
                            skills: nil,
                            interests: nil,
                            energy: 0.5,
                            lastSeen: device.lastSeen
                        )
                        injected.append(attendee)

                        #if DEBUG
                        print("[NearbyMode] injecting BLE attendee (anonymous): \(name) (prefix: \(prefix))")
                        #endif
                    }
                }

                if !injected.isEmpty {
                    // Merge with existing attendees (preserve any cached ones from previous online session)
                    let existingIds = Set(self.attendees.map(\.id))
                    let newOnly = injected.filter { !existingIds.contains($0.id) }
                    self.attendees.append(contentsOf: newOnly)
                    self.attendeeCount = self.attendees.count
                    self.debugStatus = "offline: \(self.attendees.count) attendee(s) via BLE+cache"

                    #if DEBUG
                    print("[NearbyMode] total attendees after injection: \(self.attendees.count)")
                    #endif
                }
            }
    }

    // MARK: - Fetch Attendees

    private func fetchAttendees() async {
        // Skip network fetch when offline — BLE fallback handles attendee injection
        guard NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("[NearbyMode] skipping backend feature: attendees refresh")
            #endif
            return
        }

        guard let eventId = presence.currentContextId,
              let currentProfileId = presence.currentCommunityId else {
            #if DEBUG
            print("[Attendees] fetchAttendees aborted: missing eventId/profileId")
            print("[Attendees]   eventId: \(presence.currentContextId?.uuidString ?? "nil")")
            print("[Attendees]   currentProfileId: \(presence.currentCommunityId?.uuidString ?? "nil")")
            #endif
            return
        }

        isLoading = true

        do {
            #if DEBUG
            print("[Attendees] ─────────────────────────────────────────")
            print("[Attendees] Fetching attendees")
            print("[Attendees]   eventId: \(eventId.uuidString)")
            print("[Attendees]   currentProfileId: \(currentProfileId.uuidString)")
            print("[Attendees]   activeWindow: \(Int(activeWindow))s")
            #endif

            let rows: [AttendeeEventRow] = try await supabase
                .from("event_attendees")
                .select("id, event_id, profile_id, status, joined_at, last_seen_at")
                .eq("event_id", value: eventId.uuidString)
                .eq("status", value: "joined")
                .neq("profile_id", value: currentProfileId.uuidString)
                .order("last_seen_at", ascending: false)
                .limit(100)
                .execute()
                .value

            #if DEBUG
            print("[Attendees]   joined rows fetched: \(rows.count)")
            for row in rows {
                print("[Attendees]   row profile_id=\(row.profileId.uuidString) status=\(row.status) last_seen_at=\(row.lastSeenAt)")
            }
            #endif

            let recentCutoff = Date().addingTimeInterval(-activeWindow)
            let now = Date()
            let liveCutoff: TimeInterval = 60.0  // "here now" threshold

            // Split rows into three tiers:
            // - live: heartbeat < 60s → shown as "here now"
            // - stale: heartbeat 60–300s → still shown, but secondary
            // - expired: heartbeat > 300s → dropped entirely
            let activeRows = rows.filter { $0.lastSeenAt >= recentCutoff }
            let liveRows = activeRows.filter { now.timeIntervalSince($0.lastSeenAt) < liveCutoff }
            let staleRows = activeRows.filter { now.timeIntervalSince($0.lastSeenAt) >= liveCutoff }
            let expiredRows = rows.filter { $0.lastSeenAt < recentCutoff }

            #if DEBUG
            print("[Attendees]   recent cutoff: \(recentCutoff)")
            print("[Attendees]   live (< \(Int(liveCutoff))s): \(liveRows.count)")
            print("[Attendees]   stale (\(Int(liveCutoff))–\(Int(activeWindow))s): \(staleRows.count) (shown as recently seen)")
            print("[Attendees]   expired (> \(Int(activeWindow))s): \(expiredRows.count)")
            for row in liveRows {
                let age = Int(now.timeIntervalSince(row.lastSeenAt))
                print("[Attendees]   ✅ live profile_id=\(row.profileId.uuidString.prefix(8)) age=\(age)s")
            }
            for row in staleRows {
                let age = Int(now.timeIntervalSince(row.lastSeenAt))
                print("[Attendees]   ⏳ stale profile_id=\(row.profileId.uuidString.prefix(8)) age=\(age)s → shown as secondary")
            }
            for row in expiredRows {
                let age = Int(now.timeIntervalSince(row.lastSeenAt))
                print("[Attendees]   ⏰ expired profile_id=\(row.profileId.uuidString.prefix(8)) age=\(age)s → dropped")
            }
            #endif

            if activeRows.isEmpty {
                let sig = "active:0"
                if sig != lastFetchSignature {
                    lastFetchSignature = sig
                    #if DEBUG
                    print("[Attendees] No active attendees")
                    #endif
                }

                attendees = []
                attendeeCount = 0
                debugStatus = "No attendees in active window"
                isLoading = false

                // No live attendees → target is not present
                evaluateTargetIntent(activeAttendeeIds: [])

                return
            }

            let orderedActiveRows = (liveRows + staleRows)
                .sorted { lhs, rhs in
                    let lhsIsLive = now.timeIntervalSince(lhs.lastSeenAt) < liveCutoff
                    let rhsIsLive = now.timeIntervalSince(rhs.lastSeenAt) < liveCutoff

                    if lhsIsLive != rhsIsLive { return lhsIsLive && !rhsIsLive }
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }

            let profileIds = Array(Set(orderedActiveRows.map(\.profileId)))

            #if DEBUG
            print("[Attendees]   requesting profiles for \(profileIds.count) id(s)")
            for id in profileIds {
                print("[Attendees]   requested profileId=\(id.uuidString)")
            }
            #endif

            let profilesById = try await fetchProfiles(for: profileIds)

            #if DEBUG
            print("[Attendees]   fetched profiles: \(profilesById.count)")
            for (id, profile) in profilesById {
                print("[Attendees]   profile \(id.uuidString) -> \(profile.name)")
            }
            #endif

            var seenProfileIds = Set<UUID>()
            let newAttendees: [EventAttendee] = orderedActiveRows.compactMap { row in
                guard seenProfileIds.insert(row.profileId).inserted else { return nil }

                let profile = profilesById[row.profileId]
                return EventAttendee(
                    id: row.profileId,
                    name: profile?.name ?? "User \(row.profileId.uuidString.prefix(8))",
                    avatarUrl: profile?.avatarUrl,
                    bio: profile?.bio,
                    skills: nil,
                    interests: nil,
                    energy: 1.0,
                    lastSeen: row.lastSeenAt
                )
            }

            #if DEBUG
            print("[Attendees]   built attendees: \(newAttendees.count)")
            for attendee in newAttendees {
                let hasImage = attendee.avatarUrl != nil ? "✓" : "–"
                print("[Attendees]   attendee -> \(attendee.name) (avatar:\(hasImage))")
            }
            #endif

            let signature = newAttendees
                .map { "\($0.id.uuidString)|\($0.lastSeen.timeIntervalSince1970)" }
                .joined(separator: ",")

            let changed = signature != lastFetchSignature
            lastFetchSignature = signature

            #if DEBUG
            if changed {
                print("[Attendees] ✅ Published \(newAttendees.count) attendee(s)")
            } else {
                print("[Attendees] ℹ️ No attendee list change")
            }
            #endif

            attendees = newAttendees
            attendeeCount = newAttendees.count
            debugStatus = "\(liveRows.count) live, \(staleRows.count) recently seen"

            // Populate offline profile cache
            ProfileCache.shared.storeAttendees(newAttendees)

            // ── Target Intent Detection ──
            evaluateTargetIntent(activeAttendeeIds: Set(liveRows.map(\.profileId)))

        } catch {
            debugStatus = "query failed: \(error.localizedDescription)"
            print("[Attendees] ❌ Query failed: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Target Intent Detection

    /// Evaluates target intent against the current active attendee set.
    /// Called on every attendee refresh cycle.
    private func evaluateTargetIntent(activeAttendeeIds: Set<UUID>) {
        let intent = TargetIntentManager.shared
        guard intent.isActive, let targetId = intent.targetProfileId else { return }

        #if DEBUG
        print("[TargetResolution] checking for target: \(intent.targetName ?? "unknown")")
        #endif

        if activeAttendeeIds.contains(targetId) {
            intent.markFound()
        } else {
            intent.markNotPresent()
        }
    }

    // MARK: - Profile Resolution

    private func fetchProfiles(for profileIds: [UUID]) async throws -> [UUID: ProfileInfo] {
        guard !profileIds.isEmpty else { return [:] }

        let cappedIds = Array(profileIds.prefix(50))
        if profileIds.count > 50 {
            print("[Attendees] ⚠️ Capped profile fetch from \(profileIds.count) to 50 IDs")
        }

        let rows: [ProfileRow] = try await supabase
            .from("profiles")
            .select("id, name, avatar_url, bio")
            .in("id", values: cappedIds.map { $0.uuidString })
            .execute()
            .value

        #if DEBUG
        print("[Attendees] fetchProfiles returned \(rows.count) row(s)")
        if rows.count != cappedIds.count {
            print("[Attendees] ⚠️ Missing profiles for \(cappedIds.count - rows.count) attendee(s)")
        }
        #endif

        return Dictionary(uniqueKeysWithValues:
            rows.map {
                ($0.id, ProfileInfo(
                    name: $0.name,
                    avatarUrl: $0.avatarUrl,
                    bio: $0.bio
                ))
            }
        )
    }

    // MARK: - Public API

    func refresh() {
        Task {
            await fetchAttendees()
        }
    }
}

// MARK: - Database Models

private struct AttendeeEventRow: Codable {
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

private struct ProfileRow: Codable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let bio: String?

    enum CodingKeys: String, CodingKey {
        case id, name, bio
        case avatarUrl = "avatar_url"
    }
}

private struct ProfileInfo {
    let name: String
    let avatarUrl: String?
    let bio: String?
}
