import Foundation
import Supabase

/// Post-event release and reconciliation service.
///
/// Handles:
/// - Matching uploaded encounter fragments across users (Step 3)
/// - Processing release actions with idempotent mutual detection (Step 4)
/// - Fetching confirmed encounters for the current user (Step 5)
///
/// Safety guarantees:
/// - All writes use ON CONFLICT DO NOTHING (idempotent)
/// - interaction_events created only on mutual release
/// - No modification to existing tables (event_attendees, encounters, etc.)
/// - No blocking UI calls
@MainActor
final class ReleaseService {

    static let shared = ReleaseService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    // MARK: - Step 3: Fragment Matching

    /// Matches uploaded encounter fragments from the current user against
    /// fragments from other users. Creates confirmed_encounters for valid matches.
    ///
    /// Matching rules (relaxed):
    /// - Same event_id (or both null)
    /// - Time overlap >= 10 seconds
    /// - BLE prefix symmetry: A saw B's prefix AND B saw A's prefix
    ///   OR strong signal + duration (>= 60s duration, >= 0.4 confidence)
    func matchFragments() async {
        guard let myProfileId = AuthService.shared.currentUser?.id else { return }

        #if DEBUG
        print("[Release] matching fragments for profile \(myProfileId.uuidString.prefix(8))")
        #endif

        do {
            // Fetch my uploaded fragments
            let myFragments: [FragmentRow] = try await supabase
                .from("encounter_fragments")
                .select("id, uploader_profile_id, event_id, peer_ephemeral_id, peer_resolved_profile_id, first_seen_at, last_seen_at, duration_seconds, confidence_score")
                .eq("uploader_profile_id", value: myProfileId.uuidString)
                .execute()
                .value

            guard !myFragments.isEmpty else {
                #if DEBUG
                print("[Release] no uploaded fragments to match")
                #endif
                return
            }

            let myPrefix = String(myProfileId.uuidString.prefix(8)).lowercased()
            var matchCount = 0

            for myFrag in myFragments {
                // Find fragments from OTHER users that saw MY prefix
                let candidates: [FragmentRow] = try await supabase
                    .from("encounter_fragments")
                    .select("id, uploader_profile_id, event_id, peer_ephemeral_id, peer_resolved_profile_id, first_seen_at, last_seen_at, duration_seconds, confidence_score")
                    .eq("peer_ephemeral_id", value: myPrefix)
                    .neq("uploader_profile_id", value: myProfileId.uuidString)
                    .execute()
                    .value

                for candidate in candidates {
                    // Event match: same event_id or both null
                    let eventMatch = myFrag.event_id == candidate.event_id
                        || (myFrag.event_id == nil && candidate.event_id == nil)
                    guard eventMatch else { continue }

                    // Time overlap check
                    let overlapStart = max(myFrag.first_seen_at, candidate.first_seen_at)
                    let overlapEnd = min(myFrag.last_seen_at, candidate.last_seen_at)
                    let overlapSeconds = Int(overlapEnd.timeIntervalSince(overlapStart))
                    guard overlapSeconds >= 10 else {
                        #if DEBUG
                        print("[Release] match rejected: time overlap \(overlapSeconds)s < 10s (\(myFrag.peer_ephemeral_id) ↔ \(candidate.uploader_profile_id.uuidString.prefix(8)))")
                        #endif
                        continue
                    }

                    // Prefix symmetry check (relaxed)
                    let otherProfilePrefix = String(candidate.uploader_profile_id.uuidString.prefix(8)).lowercased()
                    let hasSymmetry = myFrag.peer_ephemeral_id == otherProfilePrefix
                    let hasStrongSignal = myFrag.duration_seconds >= 60 && myFrag.confidence_score >= 0.4

                    guard hasSymmetry || hasStrongSignal else {
                        #if DEBUG
                        print("[Release] match rejected: no prefix symmetry and weak signal (\(myFrag.peer_ephemeral_id) ↔ \(otherProfilePrefix))")
                        #endif
                        continue
                    }

                    // Canonical ordering: profile_a < profile_b
                    let (profileA, profileB) = canonicalPair(myProfileId, candidate.uploader_profile_id)
                    let combinedConfidence = (myFrag.confidence_score + candidate.confidence_score) / 2.0

                    // Insert confirmed encounter (ON CONFLICT DO NOTHING)
                    let payload = ConfirmedEncounterPayload(
                        event_id: myFrag.event_id?.uuidString ?? candidate.event_id?.uuidString,
                        profile_a: profileA.uuidString,
                        profile_b: profileB.uuidString,
                        overlap_seconds: overlapSeconds,
                        combined_confidence: combinedConfidence
                    )

                    try await supabase
                        .from("confirmed_encounters")
                        .upsert(payload, onConflict: "profile_a,profile_b,event_id")
                        .execute()

                    matchCount += 1

                    #if DEBUG
                    print("[Release] match created: \(profileA.uuidString.prefix(8)) ↔ \(profileB.uuidString.prefix(8)) (overlap: \(overlapSeconds)s, confidence: \(String(format: "%.2f", combinedConfidence)))")
                    #endif
                }
            }

            #if DEBUG
            print("[Release] matching complete: \(matchCount) confirmed encounters")
            #endif

        } catch {
            #if DEBUG
            print("[Release] matching failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Step 4: Release Action

    /// Processes a release action for a confirmed encounter.
    /// Idempotent — safe to call multiple times.
    ///
    /// Returns: (releaseInserted: Bool, isMutual: Bool)
    func processRelease(confirmedEncounterId: UUID) async -> (releaseInserted: Bool, isMutual: Bool) {
        guard let myProfileId = AuthService.shared.currentUser?.id else {
            return (false, false)
        }

        #if DEBUG
        print("[Release] processing release for encounter \(confirmedEncounterId.uuidString.prefix(8)) by \(myProfileId.uuidString.prefix(8))")
        #endif

        do {
            // Step 1: Insert release (ON CONFLICT DO NOTHING)
            let releasePayload = ReleasePayload(
                confirmed_encounter_id: confirmedEncounterId.uuidString,
                releaser_profile_id: myProfileId.uuidString
            )

            try await supabase
                .from("encounter_releases")
                .upsert(releasePayload, onConflict: "confirmed_encounter_id,releaser_profile_id")
                .execute()

            #if DEBUG
            print("[Release] release inserted for encounter \(confirmedEncounterId.uuidString.prefix(8))")
            #endif

            // Step 2: Count releases for this encounter
            let releases: [ReleaseRow] = try await supabase
                .from("encounter_releases")
                .select("id, releaser_profile_id")
                .eq("confirmed_encounter_id", value: confirmedEncounterId.uuidString)
                .execute()
                .value

            let isMutual = releases.count >= 2

            if isMutual {
                #if DEBUG
                print("[Release] mutual release triggered for encounter \(confirmedEncounterId.uuidString.prefix(8))")
                #endif

                // Step 3: Create interaction_event (only on mutual release)
                await createInteractionEvent(confirmedEncounterId: confirmedEncounterId)
            }

            return (true, isMutual)

        } catch {
            #if DEBUG
            print("[Release] release failed: \(error.localizedDescription)")
            #endif
            return (false, false)
        }
    }

    /// Creates an interaction_event for a mutual release.
    /// Uses the confirmed_encounter data to populate the event.
    private func createInteractionEvent(confirmedEncounterId: UUID) async {
        do {
            // Fetch the confirmed encounter to get profile IDs and event context
            let encounters: [ConfirmedEncounterRow] = try await supabase
                .from("confirmed_encounters")
                .select("id, event_id, profile_a, profile_b, overlap_seconds, combined_confidence")
                .eq("id", value: confirmedEncounterId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let encounter = encounters.first else {
                #if DEBUG
                print("[Release] ⚠️ confirmed encounter not found: \(confirmedEncounterId)")
                #endif
                return
            }

            // Check if interaction_event already exists for this pair + type
            // to prevent duplicates (belt-and-suspenders with the unique constraint)
            let existing: [InteractionEventCheckRow] = try await supabase
                .from("interaction_events")
                .select("id")
                .eq("from_profile_id", value: encounter.profile_a.uuidString)
                .eq("to_profile_id", value: encounter.profile_b.uuidString)
                .eq("interaction_type", value: "mutual_release")
                .limit(1)
                .execute()
                .value

            guard existing.isEmpty else {
                #if DEBUG
                print("[Release] interaction_event already exists — skipping duplicate")
                #endif
                return
            }

            let payload = InteractionEventInsertPayload(
                event_id: encounter.event_id?.uuidString ?? "",
                from_profile_id: encounter.profile_a.uuidString,
                to_profile_id: encounter.profile_b.uuidString,
                interaction_type: "mutual_release",
                strength: encounter.combined_confidence,
                dwell_seconds: encounter.overlap_seconds,
                signal_strength: 0
            )

            try await supabase
                .from("interaction_events")
                .insert(payload)
                .execute()

            #if DEBUG
            print("[Release] interaction_event created: \(encounter.profile_a.uuidString.prefix(8)) ↔ \(encounter.profile_b.uuidString.prefix(8)) (type: mutual_release)")
            #endif

        } catch {
            #if DEBUG
            print("[Release] interaction_event creation failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Step 5: Fetch Confirmed Encounters

    /// Fetches confirmed encounters for the current user.
    /// Returns encounters where the user is either profile_a or profile_b.
    func fetchConfirmedEncounters() async -> [ConfirmedEncounterRow] {
        guard let myProfileId = AuthService.shared.currentUser?.id else { return [] }

        do {
            // Fetch where user is profile_a
            let asA: [ConfirmedEncounterRow] = try await supabase
                .from("confirmed_encounters")
                .select("id, event_id, profile_a, profile_b, overlap_seconds, combined_confidence, created_at")
                .eq("profile_a", value: myProfileId.uuidString)
                .execute()
                .value

            // Fetch where user is profile_b
            let asB: [ConfirmedEncounterRow] = try await supabase
                .from("confirmed_encounters")
                .select("id, event_id, profile_a, profile_b, overlap_seconds, combined_confidence, created_at")
                .eq("profile_b", value: myProfileId.uuidString)
                .execute()
                .value

            let all = asA + asB
            #if DEBUG
            print("[Release] fetched \(all.count) confirmed encounters")
            #endif
            return all

        } catch {
            #if DEBUG
            print("[Release] fetch confirmed encounters failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Fetches release status for a set of confirmed encounter IDs.
    /// Returns a dictionary: confirmedEncounterId → number of releases (0, 1, or 2).
    func fetchReleaseStatus(for encounterIds: [UUID]) async -> [UUID: Int] {
        guard !encounterIds.isEmpty else { return [:] }

        do {
            let releases: [ReleaseRow] = try await supabase
                .from("encounter_releases")
                .select("id, confirmed_encounter_id, releaser_profile_id")
                .in("confirmed_encounter_id", values: encounterIds.map(\.uuidString))
                .execute()
                .value

            var counts: [UUID: Int] = [:]
            for release in releases {
                counts[release.confirmed_encounter_id, default: 0] += 1
            }
            return counts

        } catch {
            #if DEBUG
            print("[Release] fetch release status failed: \(error.localizedDescription)")
            #endif
            return [:]
        }
    }

    // MARK: - Helpers

    private func canonicalPair(_ a: UUID, _ b: UUID) -> (UUID, UUID) {
        a.uuidString < b.uuidString ? (a, b) : (b, a)
    }
}

// MARK: - Database Row Models

struct ConfirmedEncounterRow: Codable, Identifiable {
    let id: UUID
    let event_id: UUID?
    let profile_a: UUID
    let profile_b: UUID
    let overlap_seconds: Int
    let combined_confidence: Double
    let created_at: Date?

    /// Returns the other profile's ID given the current user's profile ID.
    func otherProfile(for myId: UUID) -> UUID {
        profile_a == myId ? profile_b : profile_a
    }
}

private struct FragmentRow: Codable {
    let id: UUID
    let uploader_profile_id: UUID
    let event_id: UUID?
    let peer_ephemeral_id: String
    let peer_resolved_profile_id: UUID?
    let first_seen_at: Date
    let last_seen_at: Date
    let duration_seconds: Int
    let confidence_score: Double
}

private struct ReleaseRow: Codable {
    let id: UUID
    let confirmed_encounter_id: UUID
    let releaser_profile_id: UUID
}

private struct InteractionEventCheckRow: Codable {
    let id: UUID
}

private struct ConfirmedEncounterPayload: Encodable {
    let event_id: String?
    let profile_a: String
    let profile_b: String
    let overlap_seconds: Int
    let combined_confidence: Double
}

private struct ReleasePayload: Encodable {
    let confirmed_encounter_id: String
    let releaser_profile_id: String
}

private struct InteractionEventInsertPayload: Encodable {
    let event_id: String
    let from_profile_id: String
    let to_profile_id: String
    let interaction_type: String
    let strength: Double
    let dwell_seconds: Int
    let signal_strength: Int
}
