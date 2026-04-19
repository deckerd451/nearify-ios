import Foundation
import Combine
import Supabase

// MARK: - Explore Event Model

struct ExploreEvent: Identifiable, Equatable {
    let id: UUID
    let name: String
    let eventDescription: String?
    let location: String?
    let startsAt: Date?
    let endsAt: Date?
    let createdAt: Date?
    let activeAttendeeCount: Int

    /// Happening now: starts_at <= now AND (ends_at IS NULL OR ends_at > now)
    var isHappeningNow: Bool {
        guard let start = startsAt else { return false }
        let now = Date()
        guard now >= start else { return false }
        if let end = endsAt { return now < end }
        return true
    }

    /// Upcoming: starts_at > now
    var isUpcoming: Bool {
        guard let start = startsAt else { return false }
        return start > Date()
    }

    /// Formatted date string for display.
    var dateDisplay: String? {
        guard let start = startsAt else { return nil }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(start) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(start) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        }
        return formatter.string(from: start)
    }
}

// MARK: - Explore Events Service

/// Loads events from public.events and sections them with strict mutual exclusivity.
/// Each event appears in exactly one section. Priority order:
///   1. currentEvent (joined + active)
///   2. happeningNow (live, not joined)
///   3. upcoming (future)
///   4. recent (previously attended, not in any above section)
@MainActor
final class ExploreEventsService: ObservableObject {

    static let shared = ExploreEventsService()

    /// The event the user is currently joined to (highest priority, exclusive).
    @Published private(set) var currentEvent: ExploreEvent?
    /// Live events the user is NOT joined to.
    @Published private(set) var happeningNow: [ExploreEvent] = []
    /// Future events.
    @Published private(set) var upcoming: [ExploreEvent] = []
    /// Previously attended events not shown in any other section. Max 2.
    @Published private(set) var recent: [ExploreEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let supabase = AppEnvironment.shared.supabaseClient
    private var refreshTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await fetchAndSection() }
    }

    // MARK: - Fetch + Section (strict dedup)

    private func fetchAndSection() async {
        isLoading = true
        loadError = nil

        do {
            // 1. Fetch all active, non-deleted events
            let rows: [EventRow] = try await supabase
                .from("events")
                .select("id, slug, name, description, location, starts_at, ends_at, is_active, created_at")
                .eq("is_active", value: true)
                .is("deleted_at", value: nil)
                .order("starts_at", ascending: true)
                .limit(50)
                .execute()
                .value

            #if DEBUG
            print("[Explore] Fetched \(rows.count) active, non-deleted events")
            #endif

            // 2. Fetch attendee counts
            let eventIds = rows.map(\.id)
            let attendeeCounts = await fetchAttendeeCounts(eventIds: eventIds)

            // 3. Build models
            let allEvents = rows.map { row in
                ExploreEvent(
                    id: row.id,
                    name: row.name,
                    eventDescription: row.eventDescription,
                    location: row.location,
                    startsAt: row.startsAt,
                    endsAt: row.endsAt,
                    createdAt: row.createdAt,
                    activeAttendeeCount: attendeeCounts[row.id] ?? 0
                )
            }

            // 4. Fetch rejoin candidates (from event_attendees history)
            let myAttendedIds = await fetchMyAttendedEventIds()
            let reconnect = EventJoinService.shared.reconnectContext
            var rejoinCandidateIds = myAttendedIds
            if let reconnectId = reconnect?.eventId, let uuid = UUID(uuidString: reconnectId) {
                rejoinCandidateIds.insert(uuid)
            }

            // 5. Identify current event ID
            let currentEventId: UUID? = {
                guard let idStr = EventJoinService.shared.currentEventID,
                      let uuid = UUID(uuidString: idStr),
                      EventJoinService.shared.isEventJoined else { return nil }
                return uuid
            }()

            // ── STRICT DEDUP SECTIONING ──
            var shownIds = Set<UUID>()

            // Section 1: CURRENT EVENT (joined + active)
            var resolvedCurrent: ExploreEvent? = nil
            if let cid = currentEventId, let event = allEvents.first(where: { $0.id == cid }) {
                resolvedCurrent = event
                shownIds.insert(cid)
                #if DEBUG
                print("[Explore] Current event: \(event.name) (\(cid))")
                #endif
            } else {
                #if DEBUG
                print("[Explore] Current event: none")
                #endif
            }

            // Section 2: HAPPENING NOW (live, not joined, not already shown)
            var now = allEvents.filter { event in
                !shownIds.contains(event.id) && event.isHappeningNow
            }
            now.sort { $0.activeAttendeeCount > $1.activeAttendeeCount }
            for e in now { shownIds.insert(e.id) }

            // Section 3: UPCOMING (future, not already shown)
            var up = allEvents.filter { event in
                !shownIds.contains(event.id) && event.isUpcoming
            }
            up.sort { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
            for e in up { shownIds.insert(e.id) }

            // Section 4: REJOIN (previously attended, not already shown)
            // Fetch details for rejoin candidates not already in allEvents
            let missingRejoinIds = rejoinCandidateIds.subtracting(Set(allEvents.map(\.id)))
            let extraRejoinEvents = await fetchEventsByIds(Array(missingRejoinIds))

            let allKnownEvents = allEvents + extraRejoinEvents
            let rec = allKnownEvents.filter { event in
                !shownIds.contains(event.id) && rejoinCandidateIds.contains(event.id)
            }
            let cappedRec = Array(rec.prefix(2))
            for e in cappedRec { shownIds.insert(e.id) }

            #if DEBUG
            // Log dedup removals
            let allCandidateIds = Set(allEvents.map(\.id)).union(rejoinCandidateIds)
            let dedupRemoved = allCandidateIds.subtracting(shownIds)
            for id in dedupRemoved {
                if let name = allKnownEvents.first(where: { $0.id == id })?.name {
                    print("[Explore] Dedup removed: \(name) (\(id))")
                }
            }
            print("[Explore] Happening now count: \(now.count)")
            print("[Explore] Upcoming count: \(up.count)")
            print("[Explore] Rejoin count: \(cappedRec.count)")
            #endif

            // Publish
            currentEvent = resolvedCurrent
            happeningNow = now
            upcoming = up
            recent = cappedRec

        } catch {
            loadError = error.localizedDescription
            print("[Explore] ❌ Failed to fetch events: \(error)")
        }

        isLoading = false
    }

    // MARK: - Fetch Helpers

    private func fetchEventsByIds(_ ids: [UUID]) async -> [ExploreEvent] {
        guard !ids.isEmpty else { return [] }
        do {
            let rows: [EventRow] = try await supabase
                .from("events")
                .select("id, slug, name, description, location, starts_at, ends_at, is_active, created_at")
                .is("deleted_at", value: nil)
                .in("id", values: ids.map(\.uuidString))
                .order("created_at", ascending: false)
                .limit(5)
                .execute()
                .value
            return rows.map { row in
                ExploreEvent(
                    id: row.id, name: row.name,
                    eventDescription: row.eventDescription, location: row.location,
                    startsAt: row.startsAt, endsAt: row.endsAt,
                    createdAt: row.createdAt, activeAttendeeCount: 0
                )
            }
        } catch {
            #if DEBUG
            print("[Explore] ⚠️ Failed to fetch rejoin event details: \(error)")
            #endif
            return []
        }
    }

    private func fetchAttendeeCounts(eventIds: [UUID]) async -> [UUID: Int] {
        guard !eventIds.isEmpty else { return [:] }
        let fiveMinAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        do {
            let rows: [AttendeeCountRow] = try await supabase
                .from("event_attendees")
                .select("event_id")
                .eq("status", value: "joined")
                .gte("last_seen_at", value: fiveMinAgo)
                .in("event_id", values: eventIds.map(\.uuidString))
                .execute()
                .value
            var counts: [UUID: Int] = [:]
            for row in rows { counts[row.eventId, default: 0] += 1 }
            return counts
        } catch {
            #if DEBUG
            print("[Explore] ⚠️ Failed to fetch attendee counts: \(error)")
            #endif
            return [:]
        }
    }

    private func fetchMyAttendedEventIds() async -> Set<UUID> {
        guard let myId = AuthService.shared.currentUser?.id else { return [] }
        do {
            let rows: [AttendeeEventIdRow] = try await supabase
                .from("event_attendees")
                .select("event_id")
                .eq("profile_id", value: myId.uuidString)
                .execute()
                .value
            return Set(rows.map(\.eventId))
        } catch {
            #if DEBUG
            print("[Explore] ⚠️ Failed to fetch my attended events: \(error)")
            #endif
            return []
        }
    }
}

// MARK: - Database Row Models

private struct EventRow: Decodable {
    let id: UUID
    let slug: String?
    let name: String
    let eventDescription: String?
    let location: String?
    let startsAt: Date?
    let endsAt: Date?
    let isActive: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, location
        case eventDescription = "description"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

private struct AttendeeCountRow: Decodable {
    let eventId: UUID
    enum CodingKeys: String, CodingKey { case eventId = "event_id" }
}

private struct AttendeeEventIdRow: Decodable {
    let eventId: UUID
    enum CodingKeys: String, CodingKey { case eventId = "event_id" }
}
