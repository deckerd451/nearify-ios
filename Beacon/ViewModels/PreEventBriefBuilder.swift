import Foundation

/// Computes pre-event briefing data from existing services.
/// No new backend calls — derives everything from RelationshipMemory,
/// EventAttendees, MeetSuggestion, and the current user's profile.
@MainActor
enum PreEventBriefBuilder {

    struct Brief {
        let hereNow: [PersonSnippet]
        let likelyAttendees: [PersonSnippet]
        let conversationStarters: [String]
        let peopleToMeet: [PersonSnippet]
    }

    struct PersonSnippet: Identifiable {
        let id: UUID
        let name: String
        let avatarUrl: String?
        let contextLine: String
    }

    /// Build a brief for the given event.
    /// All data comes from already-loaded service state.
    static func build(eventId: UUID, eventName: String) -> Brief {
        let attendees = EventAttendeesService.shared.attendees
        let relationships = RelationshipMemoryService.shared.relationships
        let meetCandidates = MeetSuggestionService.shared.candidates
        let myId = AuthService.shared.currentUser?.id
        let myInterests = AuthService.shared.currentUser?.interests ?? []
        let mySkills = AuthService.shared.currentUser?.skills ?? []

        // Track shown IDs to avoid duplicates across sections
        var shownIds = Set<UUID>()
        if let myId { shownIds.insert(myId) }

        // ── 1. PEOPLE HERE NOW ──
        let hereNow: [PersonSnippet] = attendees
            .filter { $0.isHereNow && $0.id != myId }
            .prefix(5)
            .map { attendee in
                shownIds.insert(attendee.id)
                return PersonSnippet(
                    id: attendee.id,
                    name: attendee.name,
                    avatarUrl: attendee.avatarUrl,
                    contextLine: attendee.lastSeenText
                )
            }

        // ── 2. LIKELY ATTENDEES ──
        // People you've met before who have history with this event
        let likely: [PersonSnippet] = relationships
            .filter { rel in
                !shownIds.contains(rel.profileId)
                && (rel.eventContexts.contains(eventName) || rel.encounterCount >= 2)
            }
            .prefix(5)
            .map { rel in
                shownIds.insert(rel.profileId)
                let context: String
                if rel.eventContexts.contains(eventName) {
                    context = "Attended this event before"
                } else if let event = rel.eventContexts.first {
                    context = "You met at \(event)"
                } else {
                    context = "\(rel.encounterCount) encounters together"
                }
                return PersonSnippet(
                    id: rel.profileId,
                    name: rel.name,
                    avatarUrl: rel.avatarUrl,
                    contextLine: context
                )
            }

        // ── 3. CONVERSATION STARTERS ──
        var starters: [String] = []

        // From shared interests with attendees
        let attendeeInterests = attendees
            .compactMap { $0.interests }
            .flatMap { $0 }
        let sharedInterests = Set(myInterests).intersection(Set(attendeeInterests))
        if let topic = sharedInterests.first {
            starters.append("Ask about \(topic) — several people here share that interest")
        }

        // From user's own skills/interests
        if let skill = mySkills.first {
            starters.append("Mention your work in \(skill) — it's a natural opener")
        }

        // From event context
        starters.append("What brought you to \(eventName)?")

        // Generic but human
        if starters.count < 4 {
            starters.append("What are you working on right now?")
        }
        if starters.count < 5 {
            starters.append("Have you been to events like this before?")
        }

        starters = Array(starters.prefix(5))

        // ── 4. PEOPLE TO MEET ──
        let toMeet: [PersonSnippet] = meetCandidates
            .filter { !shownIds.contains($0.id) }
            .prefix(3)
            .map { candidate in
                shownIds.insert(candidate.id)
                return PersonSnippet(
                    id: candidate.id,
                    name: candidate.name,
                    avatarUrl: candidate.avatarUrl,
                    contextLine: candidate.explanation
                )
            }

        return Brief(
            hereNow: hereNow,
            likelyAttendees: Array(likely),
            conversationStarters: starters,
            peopleToMeet: Array(toMeet)
        )
    }
}
