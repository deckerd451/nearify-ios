import Foundation
import Supabase

/// Production-safe ingestion of QR-confirmed interactions into
/// `public.interaction_events` for the Nearify intelligence pipeline.
///
/// Design rules:
///   • Never blocks the QR success UI
///   • Never throws into the UI layer
///   • Retries once on transient failure, then gives up
///   • Deduplicates rapid double-fires within a 10s window
///   • Uses profiles.id (NOT auth.users.id) for all identity columns
final class NearifyIngestionService {

    static let shared = NearifyIngestionService()

    private let supabase = AppEnvironment.shared.supabaseClient
    private let maxRetries = 1

    // MARK: - Duplicate Protection

    /// Key: "eventId|fromProfileId|toProfileId|interaction_type"
    /// Value: timestamp of last successful queue
    private var recentInserts: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 10.0
    private let dedupeQueue = DispatchQueue(label: "com.nearify.ingestion.dedupe")
    private init() {}

    // MARK: - Public API

    /// Fire-and-forget: ingests a QR-confirmed interaction into `public.interaction_events`.
    ///
    /// Call this after a QR-confirmed connection succeeds. Runs entirely in the
    /// background — the caller should NOT await this.
    ///
    /// - Parameters:
    ///   - eventId: The current event UUID (from EventJoinService).
    ///   - fromProfileId: Current user's `profiles.id`.
    ///   - toProfileId: Scanned/confirmed user's `profiles.id`.
    func ingestQRConfirmedInteraction(
        eventId: UUID,
        fromProfileId: UUID,
        toProfileId: UUID
    ) {
        print("[Ingest] ENTER ingestQRConfirmedInteraction")
        print("[Ingest]   eventId        = \(eventId)")
        print("[Ingest]   fromProfileId  = \(fromProfileId)")
        print("[Ingest]   toProfileId    = \(toProfileId)")

        let interactionType = "qr_confirmed"
        let dedupeKey = "\(eventId)|\(fromProfileId)|\(toProfileId)|\(interactionType)"
        print("[Ingest]   dedupeKey      = \(dedupeKey)")

        // Duplicate check (timestamp-based suppression)
        let dominated: Bool = dedupeQueue.sync {
            if let lastTime = recentInserts[dedupeKey],
               Date().timeIntervalSince(lastTime) < dedupeWindow {
                return true
            }
            recentInserts[dedupeKey] = Date()
            return false
        }

        if dominated {
            print("[Ingest] SKIP — duplicate suppressed within \(dedupeWindow)s window")
            return
        }

        print("[Ingest] QR confirmed interaction queued for background insert")

        Task(priority: .utility) { [weak self] in
            guard let self else {
                print("[Ingest] SKIP — self was deallocated before insert task ran")
                return
            }
            await self.insertInteraction(
                eventId: eventId,
                fromProfileId: fromProfileId,
                toProfileId: toProfileId,
                interactionType: interactionType,
                attempt: 0
            )
        }
    }

    // MARK: - Legacy API (bridge)

    /// Legacy bridge: accepts community IDs and resolves event from EventJoinService.
    /// Kept for backward compatibility with existing call sites during migration.
    func ingestQRConfirmedConnection(
        fromCommunityId: UUID,
        toCommunityId: UUID,
        fromAuthUserId: UUID? = nil,
        toAuthUserId: UUID? = nil
    ) {
        print("[Ingest] ENTER legacy ingestQRConfirmedConnection")
        print("[Ingest]   fromCommunityId = \(fromCommunityId)")
        print("[Ingest]   toCommunityId   = \(toCommunityId)")
        print("[Ingest]   fromAuthUserId  = \(fromAuthUserId?.uuidString ?? "nil")")
        print("[Ingest]   toAuthUserId    = \(toAuthUserId?.uuidString ?? "nil")")

        // Resolve event ID from current session
        Task { @MainActor in
            guard let eventIdString = EventJoinService.shared.currentEventID,
                  let eventId = UUID(uuidString: eventIdString) else {
                print("[Ingest] SKIP — legacy bridge: EventJoinService.currentEventID is nil or invalid")
                return
            }

            print("[Ingest] Legacy bridge resolved eventId = \(eventId), forwarding to new API")
            // fromCommunityId and toCommunityId are already profile IDs in this codebase
            self.ingestQRConfirmedInteraction(
                eventId: eventId,
                fromProfileId: fromCommunityId,
                toProfileId: toCommunityId
            )
        }
    }

    // MARK: - Insert Logic

    private func insertInteraction(
        eventId: UUID,
        fromProfileId: UUID,
        toProfileId: UUID,
        interactionType: String,
        attempt: Int
    ) async {
        print("[Ingest] insertInteraction attempt \(attempt + 1)/\(maxRetries + 1)")

        let payload = InteractionEventPayload(
            event_id: eventId.uuidString,
            from_profile_id: fromProfileId.uuidString,
            to_profile_id: toProfileId.uuidString,
            interaction_type: interactionType,
            strength: 1.0,
            dwell_seconds: 0,
            signal_strength: 0
        )

        print("[Ingest] PRE-INSERT payload:")
        print("[Ingest]   event_id        = \(payload.event_id)")
        print("[Ingest]   from_profile_id = \(payload.from_profile_id)")
        print("[Ingest]   to_profile_id   = \(payload.to_profile_id)")
        print("[Ingest]   interaction_type = \(payload.interaction_type)")
        print("[Ingest]   strength        = \(payload.strength)")
        print("[Ingest]   dwell_seconds   = \(payload.dwell_seconds)")
        print("[Ingest]   signal_strength = \(payload.signal_strength)")

        do {
            try await supabase
                .from("interaction_events")
                .insert(payload)
                .execute()

            print("[Ingest] ✅ INSERT SUCCESS into public.interaction_events")
        } catch {
            print("[Ingest] ❌ INSERT FAILED: \(error)")
            print("[Ingest]   localizedDescription: \(error.localizedDescription)")
            print("[Ingest]   full error: \(String(describing: error))")

            if attempt < maxRetries {
                print("[Ingest] 🔄 Retrying in 2s (attempt \(attempt + 2)/\(maxRetries + 1))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await insertInteraction(
                    eventId: eventId,
                    fromProfileId: fromProfileId,
                    toProfileId: toProfileId,
                    interactionType: interactionType,
                    attempt: attempt + 1
                )
            } else {
                print("[Ingest] ⛔ GIVING UP after \(attempt + 1) attempt(s) — interaction lost")
            }
        }
    }
}

// MARK: - Payload Model

private struct InteractionEventPayload: Encodable {
    let event_id: String
    let from_profile_id: String
    let to_profile_id: String
    let interaction_type: String
    let strength: Double
    let dwell_seconds: Int
    let signal_strength: Int
}
