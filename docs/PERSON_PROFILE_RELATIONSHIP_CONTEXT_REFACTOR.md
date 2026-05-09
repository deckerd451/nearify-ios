# Person Profile Refactor: Relationship Context Layer

## Objective

Redefine boundary between **People feed** and **Person Profile** without a visual redesign:

- **People feed** = discovery + prioritization intelligence (time-sensitive)
- **Person Profile** = relationship memory + continuity (persistent)

The profile becomes a canonical Nearify relationship context layer, not a frozen recommendation artifact.

---

## 1) Current State Assessment (What belongs where)

### Keep in People Feed (Discovery / Prioritization)
These are feed-native and should not be repeated in profile:
- ranking/prioritization language ("who now")
- recommendation confidence / score explanations
- "likely to reconnect" style predictive framing
- recommendation cards and feed reasoning snippets
- section-level urgency and triage context (e.g., Here Now / Follow Up / Past)

Current feed surface and card orchestration remain in:
- `Beacon/Views/PeopleView.swift`
- `Beacon/ViewModels/PeopleIntelligenceBuilder.swift`
- `Beacon/ViewModels/PeopleIntelligenceController.swift` (if present in branch)
- feed components under `Beacon/Features/Feed/` and `Beacon/Views/Components/`

### Keep / Strengthen in Person Profile (Memory / Continuity)
Profile should own persistent relationship context:
- where you met
- events attended together
- strongest interactions and continuity timeline
- follow-up notes/promises/reminders
- collaboration history
- mutual communities/mutual links
- last meaningful interaction
- canonical identity + contact affordances

Current profile entry points to converge toward:
- `Beacon/Views/PersonDetailView.swift`
- `Beacon/Features/Feed/FeedProfileDetailView.swift`

### Redundant Concept to Remove
`NearifyContactDetailView` currently acts as a pseudo-profile and introduces duplicate detail semantics:
- `People -> Saved to Contacts -> NearifyContactDetailView -> Open in Nearify -> actual profile`

This is the core duplication that should be eliminated.

---

## 2) Canonical Surface & Navigation Proposal

## Canonical rule
There is exactly **one person detail destination** in Nearify for a known `profileId`:
- **Canonical route:** `PersonProfileRoute(profileId)` (implemented via existing profile detail view)

Everything else (feed cards, contacts list, deep links) should navigate to that canonical destination.

## Simplified flow

### Current problematic flow
`People -> Saved to Contacts -> Contact Detail -> Open in Nearify -> Profile`

### Target flow
`People -> Saved to Contacts -> Profile`

### Navigation behavior changes
1. Selecting a person from feed opens canonical profile directly.
2. Selecting a row from Nearify Contacts with `profileID` opens canonical profile directly.
3. If a contact row has no `profileID`, open Apple Contacts detail (system surface), not a Nearify pseudo-profile.
4. Remove "Open in Nearify" CTA from an intermediate detail layer by removing that layer.

---

## 3) Responsibility Matrix

### People Feed responsibilities
- discovery and triage for "right now"
- ranking/prioritization explanations
- event-time context urgency
- quick actions (message, locate, lightweight save)
- no durable relationship narrative beyond preview snippets

Primary files:
- `Beacon/Views/PeopleView.swift`
- `Beacon/ViewModels/PeopleIntelligenceBuilder.swift`
- `Beacon/ViewModels/PeopleRefreshCoordinator.swift`

### Person Profile responsibilities
- canonical person identity in Nearify
- relationship memory timeline and persistent context
- continuity actions (message, follow-up, reminder, notes)
- shared context blocks (events, collaboration, topics, promises)
- contact integration state as metadata (not alternative model)

Primary files (canonical target):
- `Beacon/Views/PersonDetailView.swift` (or merged replacement)
- `Beacon/Features/Feed/FeedProfileDetailView.swift` (should compose/use canonical content)
- services already suitable for memory-context hydration:
  - `Beacon/Services/RelationshipMemoryService.swift`
  - `Beacon/Services/ProfileService.swift`

### Apple Contacts integration responsibilities
- persistence/export state only
- status and actions on profile:
  - saved badge/state
  - open in Apple Contacts
  - edit Apple contact
  - remove from contacts
  - sync status/error state
- no independent relationship detail semantics

Primary files:
- `Beacon/Services/ContactSyncService.swift`
- `Beacon/Services/NearifyContactsIndexService.swift`
- `Beacon/Views/Components/ContactSaveFlow.swift`
- `Beacon/Views/NearifyContactsView.swift`

---

## 4) Saved to Contacts Integration Model

Treat contacts linkage as metadata on person, not separate entity.

## Proposed model extensions (conceptual)
On canonical person relationship model (or profile view model):
- `contactLinkState: .notSaved | .saved(contactId) | .syncing | .error`
- `contactLastSyncedAt`
- `contactSyncError` (optional)

This keeps Nearify person as primary identity while exposing Apple Contacts as additive persistence/export.

## UI placement
Within canonical profile (header or relationship actions section):
- "Saved to Contacts" badge/state
- "Open in Apple Contacts"
- "Edit Contact"
- "Remove from Contacts"

No separate pseudo-profile screen for these actions.

---

## 5) Migration / Refactor Plan

## Phase 1: Route unification (low risk)
1. Introduce/confirm one canonical person route keyed by `profileId`.
2. Update `NearifyContactsView` selection handling to navigate directly to canonical profile when `profileID` exists.
3. Keep fallback behavior for non-Nearify contacts (system contact view if needed).

Impacted areas:
- `Beacon/Views/NearifyContactsView.swift`
- `Beacon/App/NavigationState.swift`
- `Beacon/Views/MainTabView.swift` (if route coordination is there)

## Phase 2: Remove pseudo-profile
1. Decommission `NearifyContactDetailView` from navigation graph.
2. Remove "Open in Nearify" bridging flow and transaction-specific guardrails only needed for that detour.
3. Delete unreachable routes and dead state transitions.

Impacted areas:
- `Beacon/Views/NearifyContactDetailView.swift` (remove or keep temporarily unused behind flag)
- any route enum/case referencing contact detail intermediate screen

## Phase 3: Canonical profile content boundary hardening
1. Audit profile sections and remove feed-intelligence framing from profile.
2. Ensure profile content sections are memory/continuity-oriented.
3. Keep feed previews in feed only.

Impacted areas:
- `Beacon/Views/PersonDetailView.swift`
- `Beacon/Features/Feed/FeedProfileDetailView.swift`
- `Beacon/ViewModels/PersonIntelligenceModel.swift` (split feed-only vs profile-only properties)

## Phase 4: Contact metadata integration on profile
1. Hydrate contact link state directly in profile VM.
2. Surface save/sync/open/edit/remove actions in profile.
3. Ensure contact state updates do not alter profile identity route.

Impacted areas:
- `Beacon/Services/ContactSyncService.swift`
- `Beacon/Services/NearifyContactsIndexService.swift`
- profile view model/service layers used by canonical profile

## Phase 5: Cleanup and deep-link validation
1. Validate deep links always resolve to canonical profile.
2. Remove obsolete "open in nearify" focus-jump logic where redundant.
3. Keep people feed architecture untouched except route outputs.

Impacted areas:
- `Beacon/Services/DeepLinkManager.swift`
- `Beacon/App/NavigationState.swift`
- `Beacon/Views/PeopleView.swift`

---

## 6) Flows that can be removed entirely

- Intermediate Nearify contact pseudo-profile screen for known Nearify identities.
- "Open in Nearify" bridging CTA from that intermediate screen.
- Duplicate relationship/context sections rendered both in pseudo-profile and real profile.
- Navigation transaction complexity whose only purpose is two-hop routing to profile.

---

## 7) Preservation constraints (explicit)

This refactor preserves:
- existing relationship graph and relationship memory services
- existing People feed logic and prioritization intelligence
- contact save functionality and Apple Contacts export path
- Nearify identity links (`profileId`) and deep-link destination semantics
- existing People architecture except where route destination is simplified

---

## 8) Acceptance Criteria

1. Any Nearify person selection path lands on one canonical profile destination.
2. No duplicate "contact detail" surface duplicates profile semantics.
3. Profile contains relationship continuity context, not feed ranking rationale.
4. "Saved to Contacts" is visible as profile metadata state and actionable from profile.
5. Existing feed prioritization quality remains unchanged.
