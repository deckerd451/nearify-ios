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
        let interactionType = "qr_confirmed"
        let dedupeKey = "\(eventId)|\(fromProfileId)|\(toProfileId)|\(interactionType)"

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
            #if DEBUG
            print("[Ingest] QR confirmed interaction dropped as duplicate")
            #endif
            return
        }

        #if DEBUG
        print("[Ingest] QR confirmed interaction queued")
        print("[Ingest]    event: \(eventId)")
        print("[Ingest]    from: \(fromProfileId) → to: \(toProfileId)")
        #endif

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
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
        // Resolve event ID from current session
        Task { @MainActor in
            guard let eventIdString = EventJoinService.shared.currentEventID,
                  let eventId = UUID(uuidString: eventIdString) else {
                #if DEBUG
                print("[Ingest] ⚠️ Legacy bridge: no active event — skipping ingestion")
                #endif
                return
            }

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
        let payload = InteractionEventPayload(
            event_id: eventId.uuidString,
            from_profile_id: fromProfileId.uuidString,
            to_profile_id: toProfileId.uuidString,
            interaction_type: interactionType,
            strength: 1.0,
            dwell_seconds: 0,
            signal_strength: 0
        )

        do {
            try await supabase
                .from("interaction_events")
                .insert(payload)
                .execute()

            #if DEBUG
            print("[Ingest] QR confirmed interaction inserted")
            #endif
        } catch {
            print("[Ingest] QR confirmed interaction failed: \(error.localizedDescription)")

            if attempt < maxRetries {
                #if DEBUG
                print("[Ingest] QR confirmed interaction failed, retrying")
                #endif
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await insertInteraction(
                    eventId: eventId,
                    fromProfileId: fromProfileId,
                    toProfileId: toProfileId,
                    interactionType: interactionType,
                    attempt: attempt + 1
                )
            } else {
                print("[Ingest] ⛔ Giving up after \(attempt + 1) attempt(s)")
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
