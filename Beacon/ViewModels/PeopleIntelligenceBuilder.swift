import Foundation
import Combine

// MARK: - Build Signature

/// Lightweight signature of the inputs that affect People section assignment.
/// Used to skip rebuilds when nothing meaningful has changed.
struct PeopleBuildSignature: Equatable {
    let attendeeIds: Set<UUID>
    let blePrefixes: Set<String>
    let relationshipIds: Set<UUID>
    let connectedIds: Set<UUID>
    let isAtEvent: Bool
    let eventContextName: String?
}

// MARK: - People Intelligence Controller

/// Controls when People intelligence models are rebuilt.
/// Prevents cascade loops by:
///   1. Signature-based change detection (skip if inputs unchanged)
///   2. Stability window (min 2.0s between rebuilds)
///   3. Debounced rebuild scheduling (coalesces rapid triggers)
@MainActor
final class PeopleIntelligenceController: ObservableObject {

    static let shared = PeopleIntelligenceController()

    @Published private(set) var sections = PeopleIntelligenceBuilder.Sections(
        hereNow: [], followUp: [], yourPeople: []
    )

    private var lastSignature: PeopleBuildSignature?
    private var lastBuildTime: Date = .distantPast
    private var pendingRebuild: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Minimum interval between rebuilds. Prevents UI jitter.
    private let stabilityWindow: TimeInterval = 2.0

    /// Debounce interval for coalescing rapid triggers.
    private let debounceInterval: TimeInterval = 0.5

    private init() {
        observeSources()
    }

    // MARK: - Observation

    /// Observes only the services that affect section assignment.
    /// BLEScannerService is NOT observed — BLE prefix changes are
    /// detected via signature comparison on each debounced tick.
    private func observeSources() {
        // Attendee list changes (Supabase refresh, ~15s)
        EventAttendeesService.shared.$attendees
            .removeDuplicates { $0.map(\.id) == $1.map(\.id) }
            .sink { _ in PeopleRefreshCoordinator.shared.requestRefresh(reason: "attendees") }
            .store(in: &cancellables)

        // Relationship memory changes
        RelationshipMemoryService.shared.$relationships
            .removeDuplicates { $0.map(\.profileId) == $1.map(\.profileId) }
            .sink { _ in PeopleRefreshCoordinator.shared.requestRefresh(reason: "relationships") }
            .store(in: &cancellables)

        // Connection set changes
        AttendeeStateResolver.shared.$connectedIds
            .removeDuplicates()
            .sink { _ in PeopleRefreshCoordinator.shared.requestRefresh(reason: "connections") }
            .store(in: &cancellables)

        // Event join state changes
        EventJoinService.shared.$isEventJoined
            .removeDuplicates()
            .sink { _ in PeopleRefreshCoordinator.shared.requestRefresh(reason: "event-join") }
            .store(in: &cancellables)

        // Navigation event context changes
        NavigationState.shared.$eventContext
            .removeDuplicates()
            .sink { _ in PeopleRefreshCoordinator.shared.requestRefresh(reason: "event-context") }
            .store(in: &cancellables)

        // Periodic BLE prefix check — every 3s, only triggers rebuild if prefix set changed.
        // This replaces direct BLE observation, avoiding RSSI-driven cascade.
        Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkBLEPrefixChange() }
            .store(in: &cancellables)
    }

    // MARK: - BLE Prefix Check (decoupled from RSSI)

    private func checkBLEPrefixChange() {
        guard EventJoinService.shared.isEventJoined else { return }
        let currentPrefixes = Self.currentBLEPrefixes()
        let lastPrefixes = lastSignature?.blePrefixes ?? []
        if currentPrefixes != lastPrefixes {
            PeopleRefreshCoordinator.shared.requestRefresh(reason: "ble-prefix-change")
        }
    }

    // MARK: - Scheduled Rebuild

    /// Schedules a debounced rebuild. Multiple calls within the debounce
    /// window are coalesced into a single rebuild.
    func scheduleRebuild(reason: String) {
        pendingRebuild?.cancel()
        pendingRebuild = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(500_000_000)) // 0.5s debounce
            guard !Task.isCancelled else { return }
            self?.rebuildIfNeeded(reason: reason)
        }
    }

    /// Forces an immediate rebuild, bypassing debounce and stability window.
    /// Used for user-initiated refreshes (pull-to-refresh).
    func forceRebuild(reason: String) {
        pendingRebuild?.cancel()
        lastSignature = nil // invalidate to guarantee rebuild
        lastBuildTime = .distantPast
        rebuildIfNeeded(reason: reason)
    }

    // MARK: - Rebuild with Change Detection

    private func rebuildIfNeeded(reason: String) {
        let newSignature = Self.computeSignature()

        // Check 1: Stability window — prevent rapid rebuilds
        let elapsed = Date().timeIntervalSince(lastBuildTime)
        if elapsed < stabilityWindow && lastSignature != nil {
            #if DEBUG
            print("[People] rebuild: SKIPPED (stability window, \(String(format: "%.1f", elapsed))s < \(stabilityWindow)s)")
            #endif
            return
        }

        // Check 2: Signature comparison — skip if nothing meaningful changed
        if let last = lastSignature, last == newSignature {
            #if DEBUG
            print("[People] rebuild: SKIPPED (no meaningful change)")
            #endif
            return
        }

        // Rebuild
        lastSignature = newSignature
        lastBuildTime = Date()

        let eventContext = NavigationState.shared.eventContext
        let result = PeopleIntelligenceBuilder.build(eventContext: eventContext)
        sections = result

        #if DEBUG
        print("[People] rebuild: EXECUTED (reason: \(reason)) → hereNow=\(result.hereNow.count) followUp=\(result.followUp.count) yourPeople=\(result.yourPeople.count)")
        #endif
    }

    // MARK: - Signature Computation

    private static func computeSignature() -> PeopleBuildSignature {
        let attendees = EventAttendeesService.shared.attendees
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let isAtEvent = EventJoinService.shared.isEventJoined
        let eventContext = NavigationState.shared.eventContext

        return PeopleBuildSignature(
            attendeeIds: Set(attendees.map(\.id)),
            blePrefixes: currentBLEPrefixes(),
            relationshipIds: Set(relationships.map(\.profileId)),
            connectedIds: connectedIds,
            isAtEvent: isAtEvent,
            eventContextName: eventContext?.eventName
        )
    }

    /// Returns the current set of BCN- prefixes visible via BLE.
    /// Only the prefix set matters — RSSI changes are irrelevant.
    private static func currentBLEPrefixes() -> Set<String> {
        guard EventJoinService.shared.isEventJoined else { return [] }
        let devices = BLEScannerService.shared.getFilteredDevices()
        var prefixes = Set<String>()
        for device in devices where device.name.hasPrefix("BCN-") {
            if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                prefixes.insert(prefix)
            }
        }
        return prefixes
    }
}

// MARK: - People Intelligence Builder

/// Builds sectioned PersonIntelligence models from existing data sources.
/// Each person appears in exactly one section.
/// When `eventContext` is provided, filters and prioritizes people relevant
/// to that event — hiding unrelated global connections.
///
/// NOTE: This builder is called by PeopleIntelligenceController, which handles
/// debouncing, change detection, and stability windows. Do not call `build()`
/// directly from views — use PeopleIntelligenceController.shared.sections instead.
@MainActor
struct PeopleIntelligenceBuilder {

    struct Sections {
        let hereNow: [PersonIntelligence]
        let followUp: [PersonIntelligence]
        let yourPeople: [PersonIntelligence]
    }

    /// Build with optional event-context filtering.
    /// When `eventContext` is set, the "Your People" section only includes people
    /// with history at that event — not the full global network.
    static func build(eventContext: PeopleEventContext? = nil) -> Sections {
        let relationships = RelationshipMemoryService.shared.relationships
        let attendees = EventAttendeesService.shared.attendees
        let encounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let targetIntent = TargetIntentManager.shared
        let isAtEvent = EventJoinService.shared.isEventJoined
        let eventName = EventJoinService.shared.currentEventName

        // Current user's profile ID — required for self-exclusion.
        // If unavailable, return empty sections rather than risk showing self.
        guard let myId = AuthService.shared.currentUser?.id else {
            return Sections(hereNow: [], followUp: [], yourPeople: [])
        }

        let attendeeIds = Set(attendees.map(\.id))

        // Build intelligence for each relationship
        var hereNow: [PersonIntelligence] = []
        var followUp: [PersonIntelligence] = []
        var yourPeople: [PersonIntelligence] = []
        var processedIds = Set<UUID>()

        // Pre-compute BLE-detected profile prefixes for fast lookup.
        // A BCN- device with a matching prefix means the person is physically nearby
        // even if Supabase hasn't confirmed their presence yet.
        var bleDetectedPrefixes = Set<String>()
        if isAtEvent {
            let bcnDevices = BLEScannerService.shared.getFilteredDevices().filter { $0.name.hasPrefix("BCN-") }
            for device in bcnDevices {
                if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                    bleDetectedPrefixes.insert(prefix)
                }
            }
        }

        for rel in relationships {
            guard rel.profileId != myId else { continue }
            processedIds.insert(rel.profileId)

            // Check both Supabase attendees AND BLE detection for "here" status.
            // BLE detection is sufficient — don't wait for backend confirmation.
            let isInAttendeeList = attendeeIds.contains(rel.profileId)
            let relPrefix = String(rel.profileId.uuidString.prefix(8)).lowercased()
            let isBLEDetected = bleDetectedPrefixes.contains(relPrefix)
            let isHere = isAtEvent && (isInAttendeeList || isBLEDetected)

            // Determine presence source — BLE is primary, backend is secondary
            let source: PresenceSource
            if isBLEDetected && isInAttendeeList {
                source = .bleAndBackend
            } else if isBLEDetected {
                source = .ble
            } else if isInAttendeeList {
                source = .backend
            } else {
                source = .none
            }

            #if DEBUG
            if isHere {
                if source == .ble && isInAttendeeList == false {
                    print("[Presence] \(rel.name): source=BLE (backend says expired → BLE wins)")
                } else if source == .bleAndBackend {
                    print("[Presence] \(rel.name): source=BLE+backend")
                } else if source == .backend {
                    print("[Presence] \(rel.name): source=backend")
                }
            }
            #endif

            let isTarget = targetIntent.targetProfileId == rel.profileId
            let encounter = encounters[rel.profileId]
            let isConnected = connectedIds.contains(rel.profileId)
            let hasHighQualityEncounter =
                rel.totalOverlapSeconds >= 600
                || (encounter?.totalSeconds ?? 0) >= 600
                || rel.encounterCount >= 2
            let isSavedContact = ContactSyncService.shared.hasSavedContact(profileId: rel.profileId)

            let model = buildModel(
                rel: rel, isHere: isHere, isTarget: isTarget,
                encounter: encounter, isConnected: isConnected,
                eventName: eventName,
                presenceSource: source
            )

            switch model.presence {
            case .hereNow:  hereNow.append(model)
            case .followUp: followUp.append(model)
            case .notHere:
                // When event context is active, only include people with
                // history at this event — skip unrelated global connections.
                if let ctx = eventContext {
                    let hasEventHistory = rel.eventContexts.contains(ctx.eventName)
                        || rel.encounterCount >= 2
                        || connectedIds.contains(rel.profileId)
                    if hasEventHistory && (isConnected || hasHighQualityEncounter || isSavedContact) {
                        yourPeople.append(model)
                    }
                } else if isConnected || hasHighQualityEncounter || isSavedContact {
                    yourPeople.append(model)
                }
            }
        }

        // Add live attendees not in relationships (new people at event).
        // Only add backend-confirmed attendees if they weren't already
        // processed via relationships above.
        if isAtEvent {
            for attendee in attendees {
                guard attendee.id != myId, !processedIds.contains(attendee.id) else { continue }
                processedIds.insert(attendee.id)
                let encounter = encounters[attendee.id]
                let isConnected = connectedIds.contains(attendee.id)

                // Check if this attendee is also BLE-detected
                let attPrefix = String(attendee.id.uuidString.prefix(8)).lowercased()
                let attBLE = bleDetectedPrefixes.contains(attPrefix)
                let attSource: PresenceSource = attBLE ? .bleAndBackend : .backend

                let model = buildFromAttendee(
                    attendee: attendee, encounter: encounter,
                    isConnected: isConnected, eventName: eventName,
                    presenceSource: attSource
                )
                hereNow.append(model)
            }
        }

        // ── BLE-only attendees not in relationships or Supabase ──
        // When offline, BLE-detected peers with cached profiles can be shown
        // even if they're not in the Supabase attendee list or relationships.
        // This ensures the People/Home UI doesn't collapse to empty when offline.
        if isAtEvent {
            let cache = ProfileCache.shared
            for prefix in bleDetectedPrefixes {
                // Skip if already processed via relationships or attendees
                if let cached = cache.profile(forPrefix: prefix) {
                    guard !processedIds.contains(cached.id) else { continue }
                    processedIds.insert(cached.id)

                    let attendee = cache.offlineAttendee(forPrefix: prefix, profileId: cached.id)
                    let isConnected = connectedIds.contains(cached.id)
                    let encounter = encounters[cached.id]

                    let model = buildFromAttendee(
                        attendee: attendee, encounter: encounter,
                        isConnected: isConnected, eventName: eventName,
                        presenceSource: .ble
                    )
                    hereNow.append(model)

                    #if DEBUG
                    print("[NearbyMode] injecting BLE attendee into People: \(cached.name) (prefix: \(prefix))")
                    #endif
                }
                // If no cached profile exists for this prefix, we still can't show them
                // (no name/avatar available). They remain visible on the Find screen.
            }
        }

        // Sort each section by priority — BLE-detected people score higher
        hereNow.sort { $0.priorityScore > $1.priorityScore }
        followUp.sort { $0.priorityScore > $1.priorityScore }
        yourPeople.sort { $0.priorityScore > $1.priorityScore }

        return Sections(hereNow: hereNow, followUp: followUp, yourPeople: yourPeople)
    }

    // MARK: - Build from RelationshipMemory

    private static func buildModel(
        rel: RelationshipMemory,
        isHere: Bool,
        isTarget: Bool,
        encounter: EncounterTracker?,
        isConnected: Bool,
        eventName: String?,
        presenceSource: PresenceSource = .none
    ) -> PersonIntelligence {

        // Determine presence
        let presence: PersonPresence
        if isHere {
            presence = .hereNow
        } else if rel.needsFollowUp || (isConnected && !rel.hasConversation) {
            presence = .followUp
        } else {
            presence = .notHere
        }

        // Distilled insight — varies by presence source
        let insight: String
        switch presenceSource {
        case .ble:
            // BLE-only: detected nearby but backend hasn't confirmed yet
            insight = "Nearby · detecting signal"
        case .bleAndBackend:
            // Both sources agree — full confidence
            insight = generateInsight(
                name: rel.name, isHere: isHere, isTarget: isTarget,
                encounter: encounter, rel: rel, isConnected: isConnected
            )
        case .backend:
            // Backend-only: active heartbeat but no BLE signal
            insight = generateInsight(
                name: rel.name, isHere: isHere, isTarget: isTarget,
                encounter: encounter, rel: rel, isConnected: isConnected
            )
        case .none:
            insight = generateInsight(
                name: rel.name, isHere: isHere, isTarget: isTarget,
                encounter: encounter, rel: rel, isConnected: isConnected
            )
        }

        // Actions
        let primary: PersonAction
        let secondary: PersonAction?
        if isHere {
            primary = .find
            secondary = isConnected ? .message : .viewProfile
        } else if isTarget && TargetIntentManager.shared.resolution == .waiting {
            primary = .keepWatching
            secondary = .viewProfile
        } else if isConnected {
            primary = .message
            secondary = .viewProfile
        } else {
            primary = .viewProfile
            secondary = nil
        }
        let topTraits = TraitReasoning.topTraits(for: rel, isHereNow: isHere)
        let whyThisMatters = TraitReasoning.whyThisMattersLine(traits: topTraits)

        // Priority score — unified via InteractionScorer
        let scorerSignals = InteractionScorer.Signals(
            isBLEDetected: presenceSource == .ble || presenceSource == .bleAndBackend,
            isHeartbeatLive: presenceSource == .backend || presenceSource == .bleAndBackend,
            encounterSeconds: encounter?.totalSeconds ?? 0,
            historicalOverlapSeconds: rel.totalOverlapSeconds,
            lastSeenAt: encounter?.lastSeen ?? rel.lastEncounterAt,
            encounterCount: rel.encounterCount,
            isConnected: isConnected,
            hasConversation: rel.hasConversation,
            sharedInterestCount: rel.sharedInterests.count
        )
        let unifiedScore = InteractionScorer.score(scorerSignals)

        // Scale to existing range and add context bonuses
        // (unified score is 0–1, existing system expects ~0–76)
        var score: Double = unifiedScore * 50.0
        if isHere { score += 20 }
        if isTarget { score += 15 }
        if rel.needsFollowUp { score += 8 }

        // Deep insights — include presence source
        var deep = buildDeepInsights(
            rel: rel, isHere: isHere, isTarget: isTarget,
            encounter: encounter, isConnected: isConnected,
            eventName: eventName
        )

        // Replace generic presence insight with source-specific one
        if isHere {
            deep.removeAll { $0.category == "Presence" }
            switch presenceSource {
            case .ble:
                deep.insert(DeepInsight(category: "Presence", text: "Detected via Bluetooth · nearby"), at: 0)
            case .bleAndBackend:
                deep.insert(DeepInsight(category: "Presence", text: "Here now · confirmed"), at: 0)
            case .backend:
                deep.insert(DeepInsight(category: "Presence", text: "Active at event"), at: 0)
            case .none:
                break
            }
        }

        return PersonIntelligence(
            id: rel.profileId,
            name: rel.name,
            avatarUrl: rel.avatarUrl,
            presence: presence,
            presenceSource: presenceSource,
            connectionStatus: rel.connectionStatus,
            isTargetIntent: isTarget,
            distilledInsight: insight,
            topTraits: topTraits,
            whyThisMatters: whyThisMatters,
            primaryAction: primary,
            secondaryAction: secondary,
            surfacedTraits: Array(rel.sharedInterests.prefix(2)),
            hasMeaningfulTimeTogether: rel.totalOverlapSeconds >= 600,
            deepInsights: deep,
            priorityScore: score,
            liveEventName: isHere ? eventName : nil,
            lastEventName: rel.eventContexts.first
        )
    }

    // MARK: - Build from live attendee (no relationship history)

    private static func buildFromAttendee(
        attendee: EventAttendee,
        encounter: EncounterTracker?,
        isConnected: Bool,
        eventName: String?,
        presenceSource: PresenceSource = .backend
    ) -> PersonIntelligence {
        let isTarget = TargetIntentManager.shared.targetProfileId == attendee.id
        let topTraits = TraitReasoning.topTraits(for: attendee)
        let whyThisMatters = TraitReasoning.whyThisMattersLine(traits: topTraits)
        let insight = generateInsight(
            name: attendee.name,
            isHere: true,
            isTarget: isTarget,
            encounter: encounter,
            totalOverlapSeconds: 0,
            encounterCount: 0,
            connectionStatus: isConnected ? .accepted : .none,
            hasMessaged: false,
            needsFollowUp: false,
            sharedInterests: [],
            lastSeenEventName: eventName
        )

        // Priority score — unified via InteractionScorer
        let scorerSignals = InteractionScorer.Signals(
            isBLEDetected: presenceSource == .ble || presenceSource == .bleAndBackend,
            isHeartbeatLive: presenceSource == .backend || presenceSource == .bleAndBackend,
            encounterSeconds: encounter?.totalSeconds ?? 0,
            historicalOverlapSeconds: 0,
            lastSeenAt: encounter?.lastSeen ?? attendee.lastSeen,
            encounterCount: encounter != nil ? 1 : 0,
            isConnected: isConnected,
            hasConversation: false,
            sharedInterestCount: 0
        )
        let unifiedScore = InteractionScorer.score(scorerSignals)
        let score: Double = unifiedScore * 50.0 + 20

        var deep: [DeepInsight] = []
        if let enc = encounter, enc.totalSeconds > 0 {
            deep.append(DeepInsight(category: "Interaction", text: "You crossed paths just now"))
        }
        switch presenceSource {
        case .ble:
            deep.append(DeepInsight(category: "Presence", text: "Detected via Bluetooth · nearby"))
        case .bleAndBackend:
            deep.append(DeepInsight(category: "Presence", text: "Here now · confirmed"))
        case .backend:
            deep.append(DeepInsight(category: "Presence", text: "Active at event"))
        case .none:
            deep.append(DeepInsight(category: "Presence", text: "Here now · nearby"))
        }
        if isConnected {
            deep.append(DeepInsight(category: "Relationship", text: "Connected"))
        }
        deep.append(DeepInsight(category: "Action", text: "They're here — go say hi"))

        return PersonIntelligence(
            id: attendee.id,
            name: attendee.name,
            avatarUrl: attendee.avatarUrl,
            presence: .hereNow,
            presenceSource: presenceSource,
            connectionStatus: isConnected ? .accepted : .none,
            isTargetIntent: isTarget,
            distilledInsight: insight,
            topTraits: topTraits,
            whyThisMatters: whyThisMatters,
            primaryAction: .find,
            secondaryAction: isConnected ? .message : .viewProfile,
            surfacedTraits: Array(((attendee.interests ?? []) + (attendee.skills ?? [])).prefix(2)),
            hasMeaningfulTimeTogether: (encounter?.totalSeconds ?? 0) >= 600,
            deepInsights: deep,
            priorityScore: score,
            liveEventName: eventName,
            lastEventName: nil
        )
    }

    // MARK: - Distilled Insight (via Engine)

    /// Generates insight for a person with full RelationshipMemory data.
    private static func generateInsight(
        name: String,
        isHere: Bool,
        isTarget: Bool,
        encounter: EncounterTracker?,
        rel: RelationshipMemory,
        isConnected: Bool
    ) -> String {
        let result = generateInsight(
            name: name, isHere: isHere, isTarget: isTarget,
            encounter: encounter,
            totalOverlapSeconds: rel.totalOverlapSeconds,
            encounterCount: rel.encounterCount,
            connectionStatus: rel.connectionStatus,
            hasMessaged: rel.hasConversation,
            needsFollowUp: rel.needsFollowUp,
            sharedInterests: rel.sharedInterests,
            lastSeenEventName: rel.eventContexts.first
        )
        return result
    }

    /// Core insight generation — delegates to DistilledInsightEngine.
    private static func generateInsight(
        name: String,
        isHere: Bool,
        isTarget: Bool,
        encounter: EncounterTracker?,
        totalOverlapSeconds: Int,
        encounterCount: Int,
        connectionStatus: RelationshipConnectionStatus,
        hasMessaged: Bool,
        needsFollowUp: Bool,
        sharedInterests: [String],
        lastSeenEventName: String?
    ) -> String {
        let signals = DistilledInsightEngine.Signals(
            isHereNow: isHere,
            isTargetIntent: isTarget,
            targetResolution: TargetIntentManager.shared.resolution,
            encounterDurationSeconds: encounter?.totalSeconds ?? 0,
            totalOverlapSeconds: totalOverlapSeconds,
            encounterCount: encounterCount,
            connectionStatus: connectionStatus,
            hasMessaged: hasMessaged,
            needsFollowUp: needsFollowUp,
            sharedInterests: sharedInterests,
            lastSeenEventName: lastSeenEventName
        )

        return DistilledInsightEngine.generate(signals: signals)
    }

    // MARK: - Deep Insights

    private static func buildDeepInsights(
        rel: RelationshipMemory,
        isHere: Bool,
        isTarget: Bool,
        encounter: EncounterTracker?,
        isConnected: Bool,
        eventName: String?
    ) -> [DeepInsight] {
        var insights: [DeepInsight] = []

        // A. Interaction — what happened between you
        if rel.totalOverlapSeconds > 600 {
            if let event = rel.eventContexts.first {
                insights.append(DeepInsight(category: "Interaction", text: "You spent meaningful time together at \(event)"))
            } else {
                insights.append(DeepInsight(category: "Interaction", text: "You spent meaningful time together"))
            }
        } else if rel.totalOverlapSeconds > 120 {
            insights.append(DeepInsight(category: "Interaction", text: "You crossed paths recently"))
        }

        if rel.encounterCount >= 3 {
            insights.append(DeepInsight(category: "Interaction", text: "You've been near each other multiple times"))
        }

        if let enc = encounter, enc.totalSeconds > 0, isHere {
            insights.append(DeepInsight(category: "Interaction", text: "You crossed paths again just now"))
        }

        if let lastSeen = rel.lastEncounterAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let ago = formatter.localizedString(for: lastSeen, relativeTo: Date())
            insights.append(DeepInsight(category: "Interaction", text: "Last seen \(ago)"))
        }

        // B. Presence — only if here now
        if isHere {
            insights.append(DeepInsight(category: "Presence", text: "Here now · nearby"))
        }

        // C. Relationship — connection and conversation state
        if !rel.sharedInterests.isEmpty {
            let topics = rel.sharedInterests.prefix(3).joined(separator: ", ")
            insights.append(DeepInsight(category: "Relationship", text: "Shared interests in \(topics)"))
        }

        switch rel.connectionStatus {
        case .accepted:
            if rel.hasConversation {
                insights.append(DeepInsight(category: "Relationship", text: "Connected · you've already messaged"))
            } else {
                insights.append(DeepInsight(category: "Relationship", text: "Connected · you haven't followed up yet"))
            }
        case .pending:
            insights.append(DeepInsight(category: "Relationship", text: "Connection pending"))
        case .none:
            break
        }

        // D. Action — why this action, in human terms
        if isHere {
            insights.append(DeepInsight(category: "Action", text: "They're here — go say hi"))
        } else if isTarget {
            insights.append(DeepInsight(category: "Action", text: "You were looking for them"))
        } else if isConnected && !rel.hasConversation {
            insights.append(DeepInsight(category: "Action", text: "You're connected — start a conversation"))
        } else if rel.needsFollowUp {
            insights.append(DeepInsight(category: "Action", text: "Worth following up before the moment passes"))
        } else if isConnected {
            insights.append(DeepInsight(category: "Action", text: "Stay in touch — send a message"))
        }

        return insights
    }
}
