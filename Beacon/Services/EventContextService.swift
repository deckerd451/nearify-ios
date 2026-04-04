import Foundation
import Supabase

// MARK: - Event Context Model

struct EventContext: Decodable {
    let eventId: UUID
    let profileId: UUID
    let intentPrimary: String?
    let intentSecondary: [String]?
    let goals: [String: String]?
    let constraints: [String: String]?
    let energyLevel: Int?
    let joinedAt: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case profileId = "profile_id"
        case intentPrimary = "intent_primary"
        case intentSecondary = "intent_secondary"
        case goals
        case constraints
        case energyLevel = "energy_level"
        case joinedAt = "joined_at"
    }
}

// MARK: - Event Context Service

/// Fetches and caches event context from `public.get_event_context(p_event_id)`.
/// Used to enrich interaction intelligence after event join.
final class EventContextService {

    static let shared = EventContextService()

    private let supabase = AppEnvironment.shared.supabaseClient

    /// In-memory cache for the active event session.
    private(set) var cachedContext: EventContext?
    private var cachedEventId: UUID?

    private init() {}

    // MARK: - Public API

    /// Fetches event context for the given event. Caches the result in memory.
    /// Fails gracefully — never throws into the caller.
    func fetchContext(eventId: UUID) async {
        // Skip if already cached for this event
        if cachedEventId == eventId, cachedContext != nil {
            #if DEBUG
            print("[EventContext] ℹ️ Already cached for event \(eventId)")
            #endif
            return
        }

        #if DEBUG
        print("[EventContext] 🔍 Fetching context for event \(eventId)")
        #endif

        do {
            let context: EventContext = try await supabase
                .rpc("get_event_context", params: ["p_event_id": eventId.uuidString])
                .single()
                .execute()
                .value

            cachedContext = context
            cachedEventId = eventId

            #if DEBUG
            print("[EventContext] ✅ Context cached — profile: \(context.profileId), intent: \(context.intentPrimary ?? "none")")
            #endif
        } catch {
            print("[EventContext] ⚠️ Failed to fetch context: \(error.localizedDescription)")
            // Fail gracefully — do not crash or propagate
        }
    }

    /// Clears the cached context (e.g. on event leave).
    func clearCache() {
        cachedContext = nil
        cachedEventId = nil

        #if DEBUG
        print("[EventContext] 🧹 Cache cleared")
        #endif
    }
}
