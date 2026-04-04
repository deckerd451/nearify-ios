import Foundation
import Supabase

/// Fire-and-forget ingestion of QR-confirmed interactions into the
/// Innovation Engine pipeline via `public.ingest_nearify_interaction`.
///
/// Design rules:
///   • Never blocks the QR success UI
///   • Never crashes on failure
///   • Retries once on transient error, then gives up
///   • Prefers community IDs; falls back to auth IDs
final class NearifyIngestionService {

    static let shared = NearifyIngestionService()

    private let supabase = AppEnvironment.shared.supabaseClient
    private let maxRetries = 1

    private init() {}

    // MARK: - Public API

    /// Call after a QR-confirmed connection succeeds.
    /// Runs entirely in the background — caller should not await this.
    func ingestQRConfirmedConnection(
        fromCommunityId: UUID,
        toCommunityId: UUID,
        fromAuthUserId: UUID? = nil,
        toAuthUserId: UUID? = nil
    ) {
        let eventId = EventJoinService.shared.currentEventID

        let payload = IngestionPayload(
            p_event_id: eventId,
            p_from_community_id: fromCommunityId.uuidString,
            p_to_community_id: toCommunityId.uuidString,
            p_from_auth_user_id: fromAuthUserId?.uuidString,
            p_to_auth_user_id: toAuthUserId?.uuidString,
            p_signal_type: "qr_confirmed",
            p_confidence: 100,
            p_occurred_at: ISO8601DateFormatter().string(from: Date()),
            p_meta: IngestionMeta(
                source: "nearify-ios",
                qr_confirmed: true,
                source_version: Self.appVersion
            )
        )

        Task.detached(priority: .utility) { [weak self] in
            await self?.send(payload: payload, attempt: 0)
        }
    }

    // MARK: - Internals

    private func send(payload: IngestionPayload, attempt: Int) async {
        #if DEBUG
        print("[Ingestion] 🚀 Sending QR-confirmed interaction (attempt \(attempt + 1))")
        print("[Ingestion]    from: \(payload.p_from_community_id) → to: \(payload.p_to_community_id)")
        print("[Ingestion]    event: \(payload.p_event_id ?? "none")")
        #endif

        do {
            try await supabase
                .rpc("ingest_nearify_interaction", params: payload)
                .execute()

            #if DEBUG
            print("[Ingestion] ✅ Ingestion succeeded")
            #endif
        } catch {
            print("[Ingestion] ❌ Ingestion failed: \(error.localizedDescription)")

            if attempt < maxRetries {
                #if DEBUG
                print("[Ingestion] 🔄 Retrying in 2s…")
                #endif
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await send(payload: payload, attempt: attempt + 1)
            } else {
                print("[Ingestion] ⛔ Giving up after \(attempt + 1) attempt(s)")
            }
        }
    }

    // MARK: - App Version

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: - Payload Models

private struct IngestionMeta: Encodable {
    let source: String
    let qr_confirmed: Bool
    let source_version: String
}

private struct IngestionPayload: Encodable {
    let p_event_id: String?
    let p_from_community_id: String
    let p_to_community_id: String
    let p_from_auth_user_id: String?
    let p_to_auth_user_id: String?
    let p_signal_type: String
    let p_confidence: Int
    let p_occurred_at: String
    let p_meta: IngestionMeta
}
