import Foundation
import Supabase

@MainActor
final class RecapFallbackService {
    static let shared = RecapFallbackService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() {}

    func buildFallbackSummary(for event: ExploreEvent) async -> PostEventSummary? {
        guard let myProfileId = AuthService.shared.currentUser?.id else {
            print("[RecapFallback] unavailable: missing current profile id")
            return nil
        }

        // 1) Pull all interaction rows for this user/event (both directions)
        let eventId = event.id.uuidString
        let profileId = myProfileId.uuidString

        do {
            let interactions: [InteractionEventRecapRow] = try await supabase
                .from("interaction_events")
                .select("from_profile_id, to_profile_id, from_ghost_id, claimed_by_profile_id, interaction_type, strength, dwell_seconds, created_at")
                .eq("event_id", value: eventId)
                .execute()
                .value

            guard !interactions.isEmpty else {
                print("[RecapFallback] unavailable: no interaction_events for event \(event.id)")
                return nil
            }

            var byPerson: [UUID: PersonAggregate] = [:]
            var usableRows = 0
            var skippedNullParticipants = 0
            for row in interactions {
                let involvesCurrentProfile = row.fromProfileId == myProfileId
                    || row.toProfileId == myProfileId
                    || row.claimedByProfileId == myProfileId
                guard involvesCurrentProfile else { continue }

                let candidates: [UUID?] = [row.fromProfileId, row.toProfileId, row.claimedByProfileId]
                let otherId = candidates
                    .compactMap { $0 }
                    .first { $0 != myProfileId }

                guard let otherId else {
                    skippedNullParticipants += 1
                    continue
                }

                usableRows += 1
                var bucket = byPerson[otherId, default: PersonAggregate()]
                bucket.totalEvents += 1
                bucket.totalDwellSeconds += max(0, row.dwellSeconds ?? 0)
                bucket.totalStrength += max(0, row.strength ?? 0)
                if let type = row.interactionType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
                    bucket.interactionTypes[type, default: 0] += 1
                }
                byPerson[otherId] = bucket
            }
            print("[RecapFallback] rows=\(interactions.count) usable=\(usableRows) skipped_null_participants=\(skippedNullParticipants)")

            guard usableRows > 0, !byPerson.isEmpty else {
                print("[RecapFallback] unavailable: no usable interaction participants for event \(event.id)")
                return nil
            }

            let personIds = Array(byPerson.keys)
            let profiles = await fetchProfiles(for: personIds)
            let connectedIds = await fetchConnectedIds(me: myProfileId, others: personIds)

            let strongestId = byPerson.max { lhs, rhs in
                lhs.value.score < rhs.value.score
            }?.key

            let strongestProfile = strongestId.flatMap { id -> ProfileSnapshot? in
                let profile = profiles[id]
                return ProfileSnapshot(
                    id: id,
                    name: profile?.name ?? "Person",
                    avatarUrl: profile?.avatarUrl,
                    contextLine: strongestContextLine(for: byPerson[id], connected: connectedIds.contains(id))
                )
            }

            let keyPeople: [KeyPerson] = byPerson
                .sorted { $0.value.score > $1.value.score }
                .prefix(5)
                .map { id, aggregate in
                    let profile = profiles[id]
                    let mins = aggregate.totalDwellSeconds / 60
                    let reason = mins > 0
                        ? "Met for \(mins)m across \(aggregate.totalEvents) interactions"
                        : "\(aggregate.totalEvents) interaction\(aggregate.totalEvents == 1 ? "" : "s")"

                    return KeyPerson(
                        id: id,
                        profile: ProfileSnapshot(
                            id: id,
                            name: profile?.name ?? "Person",
                            avatarUrl: profile?.avatarUrl,
                            contextLine: reason
                        ),
                        reason: reason,
                        signalTier: aggregate.signalTier
                    )
                }

            let suggestions: [FollowUpSuggestion] = keyPeople
                .filter { !connectedIds.contains($0.id) }
                .prefix(2)
                .map { person in
                    FollowUpSuggestion(
                        id: person.id,
                        type: .followUp,
                        targetProfile: person.profile,
                        reason: "You had multiple interactions at \(event.name).",
                        confidence: 0.6
                    )
                }

            let summary = PostEventSummary(
                eventName: event.name,
                totalPeopleMet: byPerson.count,
                snapshot: EventSnapshot(
                    attendedMinutes: nil,
                    meaningfulPeopleCount: keyPeople.count,
                    activityLine: "\(usableRows) interactions captured"
                ),
                keyPeople: keyPeople,
                strongestInteraction: strongestProfile,
                recentConnections: keyPeople.filter { connectedIds.contains($0.id) }.map(\.profile),
                missedConnections: [],
                followUpSuggestions: suggestions,
                narrativeWrapUp: "You met \(byPerson.count) people at \(event.name)."
            )

            print("[RecapFallback] source=supabase fallback built for event \(event.id) people=\(summary.totalPeopleMet)")
            return summary
        } catch {
            print("[RecapFallback] error loading fallback for event \(event.id): \(error)")
            return nil
        }
    }

    private func fetchProfiles(for ids: [UUID]) async -> [UUID: RecapProfileRow] {
        guard !ids.isEmpty else { return [:] }
        let filter = ids.map { "id.eq.\($0.uuidString)" }.joined(separator: ",")
        do {
            let rows: [RecapProfileRow] = try await supabase
                .from("profiles")
                .select("id, name, avatar_url")
                .or(filter)
                .execute()
                .value
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        } catch {
            print("[RecapFallback] profiles fetch failed: \(error)")
            return [:]
        }
    }

    private func fetchConnectedIds(me: UUID, others: [UUID]) async -> Set<UUID> {
        guard !others.isEmpty else { return [] }
        do {
            let rows: [ConnectionRow] = try await supabase
                .from("connections")
                .select("requester_profile_id, addressee_profile_id")
                .eq("status", value: "accepted")
                .or("requester_profile_id.eq.\(me.uuidString),addressee_profile_id.eq.\(me.uuidString)")
                .execute()
                .value

            var connected = Set<UUID>()
            let othersSet = Set(others)
            for row in rows {
                let other = row.requesterId == me ? row.addresseeId : row.requesterId
                if othersSet.contains(other) {
                    connected.insert(other)
                }
            }
            return connected
        } catch {
            print("[RecapFallback] connections fetch failed: \(error)")
            return []
        }
    }

    private func strongestContextLine(for aggregate: PersonAggregate?, connected: Bool) -> String {
        guard let aggregate else { return connected ? "Connected" : "Strong signal" }
        let mins = aggregate.totalDwellSeconds / 60
        let lead = mins > 0 ? "~\(mins)m together" : "\(aggregate.totalEvents) interactions"
        return connected ? "\(lead) · connected" : lead
    }
}

private struct InteractionEventRecapRow: Decodable {
    let fromProfileId: UUID?
    let toProfileId: UUID?
    let fromGhostId: UUID?
    let claimedByProfileId: UUID?
    let interactionType: String?
    let strength: Double?
    let dwellSeconds: Int?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case fromProfileId = "from_profile_id"
        case toProfileId = "to_profile_id"
        case fromGhostId = "from_ghost_id"
        case claimedByProfileId = "claimed_by_profile_id"
        case interactionType = "interaction_type"
        case strength
        case dwellSeconds = "dwell_seconds"
        case createdAt = "created_at"
    }
}

private struct RecapProfileRow: Decodable {
    let id: UUID
    let name: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarUrl = "avatar_url"
    }
}

private struct ConnectionRow: Decodable {
    let requesterId: UUID
    let addresseeId: UUID

    enum CodingKeys: String, CodingKey {
        case requesterId = "requester_profile_id"
        case addresseeId = "addressee_profile_id"
    }
}

private struct PersonAggregate {
    var totalEvents: Int = 0
    var totalDwellSeconds: Int = 0
    var totalStrength: Double = 0
    var interactionTypes: [String: Int] = [:]

    var score: Double {
        Double(totalDwellSeconds) + totalStrength * 60.0 + Double(totalEvents * 15)
    }

    var signalTier: KeyPerson.SignalTier {
        if totalDwellSeconds >= 180 || totalEvents >= 3 || totalStrength >= 2.0 {
            return .high
        }
        if totalDwellSeconds >= 60 || totalEvents >= 2 {
            return .medium
        }
        return .low
    }
}
