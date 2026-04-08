import Foundation

// MARK: - Encounter

/// Decoded row from the `encounters` table.
/// Represents a BLE-derived proximity overlap between two profiles at an event.
struct Encounter: Codable, Identifiable {
    let id: UUID
    let eventId: UUID?
    let profileA: UUID
    let profileB: UUID
    let firstSeenAt: Date?
    let lastSeenAt: Date?
    let overlapSeconds: Int?
    let confidence: Double?
    
    enum CodingKeys: String, CodingKey {
        case id
        case eventId        = "event_id"
        case profileA       = "profile_a"
        case profileB       = "profile_b"
        case firstSeenAt    = "first_seen_at"
        case lastSeenAt     = "last_seen_at"
        case overlapSeconds = "overlap_seconds"
        case confidence
    }
    
    /// Returns the other profile's ID given the current user's profile ID.
    func otherProfile(for myId: UUID) -> UUID {
        profileA == myId ? profileB : profileA
    }
    
    /// Human-readable overlap duration
    var overlapText: String {
        guard let seconds = overlapSeconds, seconds > 0 else { return "Brief encounter" }
        let minutes = seconds / 60
        if minutes < 1 { return "\(seconds)s nearby" }
        return "\(minutes) min nearby"
    }
}
