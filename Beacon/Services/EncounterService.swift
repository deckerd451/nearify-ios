import Foundation
import Combine
import Supabase

/// Records BLE-derived encounters to the `encounters` table.
/// Integrates with BLEScannerService to detect proximity overlaps
/// and persists them for the Social Memory Feed.
@MainActor
final class EncounterService: ObservableObject {
    
    static let shared = EncounterService()
    
    @Published private(set) var activeEncounters: [UUID: EncounterTracker] = [:]
    
    private let supabase = AppEnvironment.shared.supabaseClient
    private let scanner = BLEScannerService.shared
    private let attendees = EventAttendeesService.shared
    
    private var flushTask: Task<Void, Never>?
    private var isFlushLoopRunning = false
    private let flushInterval: TimeInterval = 30.0
    private let minimumOverlapSeconds = 30 // Don't record < 30s encounters
    
    private init() {}
    
    // MARK: - Tracking
    
    /// Call periodically (e.g., every scanner refresh) to update encounter tracking.
    /// Matches BLE devices to attendees and accumulates overlap time.
    func updateFromBLE() {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        guard let eventId = EventJoinService.shared.currentEventID,
              let eventUUID = UUID(uuidString: eventId) else { return }
        
        let devices = scanner.getFilteredDevices()
        let currentAttendees = attendees.attendees
        let now = Date()
        
        for device in devices where device.name.hasPrefix("BCN-") {
            guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { continue }
            guard let attendee = currentAttendees.first(where: {
                String($0.id.uuidString.prefix(8)).lowercased() == prefix
            }) else { continue }
            
            // Don't track self
            guard attendee.id != myId else { continue }
            
            if var tracker = activeEncounters[attendee.id] {
                tracker.lastSeen = now
                tracker.totalSeconds += Int(now.timeIntervalSince(tracker.lastTick))
                tracker.lastTick = now
                activeEncounters[attendee.id] = tracker
            } else {
                activeEncounters[attendee.id] = EncounterTracker(
                    profileId: attendee.id,
                    eventId: eventUUID,
                    firstSeen: now,
                    lastSeen: now,
                    lastTick: now,
                    totalSeconds: 0
                )
            }
        }
    }
    
    // MARK: - Flush to DB
    
    /// Starts periodic flushing of accumulated encounters to Supabase.
    func startPeriodicFlush() {
        guard !isFlushLoopRunning else {
            #if DEBUG
            print("[Guard] Encounter flush loop already running — skipping")
            #endif
            return
        }

        isFlushLoopRunning = true
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            #if DEBUG
            print("[Guard] Encounter flush loop started")
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                await self?.flushEncounters()
            }
            await MainActor.run { self?.isFlushLoopRunning = false }
            #if DEBUG
            print("[Guard] Encounter flush loop stopped")
            #endif
        }
    }
    
    func stopPeriodicFlush() {
        flushTask?.cancel()
        flushTask = nil
        isFlushLoopRunning = false
    }
    
    /// Writes accumulated encounters to the `encounters` table.
    func flushEncounters() async {
        guard let myId = AuthService.shared.currentUser?.id else { return }
        
        let toFlush = activeEncounters.values.filter { $0.totalSeconds >= minimumOverlapSeconds }
        guard !toFlush.isEmpty else { return }
        
        for tracker in toFlush {
            let payload = EncounterUpsertPayload(
                eventId: tracker.eventId,
                profileA: myId,
                profileB: tracker.profileId,
                firstSeenAt: tracker.firstSeen,
                lastSeenAt: tracker.lastSeen,
                overlapSeconds: tracker.totalSeconds,
                confidence: min(1.0, Double(tracker.totalSeconds) / 300.0)
            )
            
            do {
                try await supabase
                    .from("encounters")
                    .upsert(payload, onConflict: "event_id,profile_a,profile_b")
                    .execute()
                
                #if DEBUG
                print("[Encounter] ✅ Flushed encounter: \(tracker.profileId) (\(tracker.totalSeconds)s)")
                #endif
            } catch {
                print("[Encounter] ❌ Failed to flush encounter: \(error)")
            }
        }
        
        // After flushing encounters, request a coalesced feed refresh
        if !toFlush.isEmpty {
            FeedService.shared.requestRefresh(reason: "encounter-flush")
        }
    }
}

// MARK: - Tracker

struct EncounterTracker {
    let profileId: UUID
    let eventId: UUID
    let firstSeen: Date
    var lastSeen: Date
    var lastTick: Date
    var totalSeconds: Int
}

// MARK: - Upsert Payload

private struct EncounterUpsertPayload: Encodable {
    let eventId: UUID
    let profileA: UUID
    let profileB: UUID
    let firstSeenAt: Date
    let lastSeenAt: Date
    let overlapSeconds: Int
    let confidence: Double
    
    enum CodingKeys: String, CodingKey {
        case eventId        = "event_id"
        case profileA       = "profile_a"
        case profileB       = "profile_b"
        case firstSeenAt    = "first_seen_at"
        case lastSeenAt     = "last_seen_at"
        case overlapSeconds = "overlap_seconds"
        case confidence
    }
}
