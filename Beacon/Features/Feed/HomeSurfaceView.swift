import SwiftUI

/// Maslow-aligned intelligence surface.
/// Renders sections in strict order: CONTINUE → INSIGHTS → NEXT MOVES.
/// Shows minimal UI when nothing meets timing + signal thresholds.
/// Reacts immediately when the user takes action.
struct HomeSurfaceView: View {
    private struct FindAttendeeDestination: Identifiable {
        let attendee: EventAttendee
        let connectionMode: FindAttendeeConnectionMode

        var id: UUID { attendee.id }
    }

    @Binding var selectedTab: AppTab
    @ObservedObject private var surface = HomeSurfaceService.shared
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var homeState = HomeStateResolver.shared
    @ObservedObject private var relationshipMemory = RelationshipMemoryService.shared
    @ObservedObject private var meetSuggestion = MeetSuggestionService.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var targetIntent = TargetIntentManager.shared
    @ObservedObject private var nearbyTracker = NearbyModeTracker.shared

    @State private var activeConversation: ConversationDestination?
    @State private var showNotConnectedAlert = false
    @State private var isOpeningConversation = false
    @State private var isConnecting = false
    @State private var navigationPath = NavigationPath()
    @State private var findAttendeeDestination: FindAttendeeDestination?
    @State private var showScanner = false
    @State private var showSoloState = false
    @State private var showStaleAttendeeAlert = false
    @State private var staleAttendeeName: String = ""
    @State private var showWrapUp = false
    @State private var isWrappingUpEvent = false

    // Arrival Brief — shown once per event session on join.
    // arrivalBriefPending: true from join until dismissed/acted on.
    // arrivalBriefEventId: tracks which event the brief was shown for.
    @State private var arrivalBriefPending = false
    @State private var hasSeenArrivalBrief = false
    @State private var arrivalBriefEventId: String?
    @State private var showBriefSheet = false

    // MARK: - Home Presentation Model

    /// Data-driven presentation model for Home.
    /// Replaces HomeState as the primary layout selector.
    /// Each case is chosen purely from available data, not synthetic lifecycle states.
    private enum HomePresentation {
        /// User is actively in an event with live attendees / featured person.
        case liveEvent(featuredPerson: HomeSurfaceItem?, eventName: String)
        /// Not in a live event, but an event suggestion exists (with optional continue person).
        case eventContinuation(suggestion: EventSuggestion, continuePerson: RelationshipMemory?)
        /// No event suggestion, but a continue-with-person candidate exists.
        case personContinuation(person: RelationshipMemory)
        /// Joining / reconnecting to an event — transient loading state.
        case joining
        /// No meaningful data — first-time or empty state.
        case onboarding

        var debugLabel: String {
            switch self {
            case .liveEvent(_, let name):                return "liveEvent: \(name)"
            case .eventContinuation(let s, _):           return "eventContinuation: \(s.eventName)"
            case .personContinuation(let p):              return "personContinuation: \(p.name)"
            case .joining:                                return "joining"
            case .onboarding:                             return "onboarding"
            }
        }
    }

    /// Resolves the current Home presentation from real data.
    /// Uses LaunchState as a stabilizer to prevent state thrashing.
    /// Priority: liveEvent → eventContinuation → personContinuation → onboarding.
    /// Recomputes automatically because every input is read through @ObservedObject properties.
    private var homePresentation: HomePresentation {
        let isJoined = eventJoin.isEventJoined
        let membership = eventJoin.membershipState
        let launchIntent = LaunchStateResolver.intent

        // 1. JOINING — transient state while connecting
        //    Only applies to genuinely transitional states (inactive during reconnect).
        //    Exit states (.left) are NOT joining — they are post-event.
        let isExitState: Bool = {
            switch membership {
            case .left, .notInEvent: return true
            default: return false
            }
        }()

        if !isJoined && !isExitState && eventJoin.joinError == nil {
            #if DEBUG
            print("[HomePresentation] joining (membership: \(membership))")
            #endif
            return .joining
        }

        // 2. DORMANT — user is still a member but app was inactive
        if case .dormant = membership {
            let eventName = eventJoin.currentEventName ?? "Event"
            #if DEBUG
            print("[HomePresentation] dormant: \(eventName)")
            #endif
            // Show as event continuation with resume prompt
            let suggestion = EventSuggestion(
                eventName: eventName,
                eventId: eventJoin.currentEventID,
                peopleMet: 0,
                isRejoinable: true,
                contextLine: "You're still part of this event"
            )
            return .eventContinuation(suggestion: suggestion, continuePerson: continueWithPersonCandidate)
        }

        // 3. LIVE EVENT — user is actively in an event (liveGuidance intent)
        if isJoined {
            let eventName = eventJoin.currentEventName ?? surface.liveEventName ?? "Event"
            let featured = featuredArrivalItem
            #if DEBUG
            print("[HomePresentation] liveEvent: \(eventName)")
            #endif
            return .liveEvent(featuredPerson: featured, eventName: eventName)
        }

        // 3. EXPLAIN AND JOIN — new user or no history
        //    Do NOT show reconnect cards or event continuation for these users.
        if launchIntent == .explainAndJoin {
            #if DEBUG
            print("[HomePresentation] onboarding (intent: explainAndJoin)")
            #endif
            return .onboarding
        }

        // 4. RESUME CONTEXT — returning user with history
        //    Show event continuation if available, then person continuation.
        if let suggestion = bestEventSuggestion {
            let person = continueWithPersonCandidate
            #if DEBUG
            print("[HomePresentation] eventContinuation: \(suggestion.eventName)")
            #endif
            return .eventContinuation(suggestion: suggestion, continuePerson: person)
        }

        if let person = continueWithPersonCandidate {
            #if DEBUG
            print("[HomePresentation] personContinuation: \(person.name)")
            #endif
            return .personContinuation(person: person)
        }

        // 5. FALLBACK — has history but nothing actionable right now
        #if DEBUG
        print("[HomePresentation] onboarding (fallback)")
        #endif
        return .onboarding
    }

    /// The single highest-priority arrival/find item promoted into the hero.
    /// Computed once, used by both the briefing hero and the continue section
    /// to avoid showing the same person twice in two large blocks.
    private var featuredArrivalItem: HomeSurfaceItem? {
        surface.continueItems.first { $0.isFind && $0.profileId != nil }
    }

    /// Whether the current presentation represents an active live event with feed data.
    /// Used to decide when to show the "Top opportunities" header and collapse the briefing.
    private var isLiveEventWithFeed: Bool {
        if case .liveEvent = homePresentation, !surface.isEmpty {
            return true
        }
        return false
    }

    /// Whether the launch/brand screen is currently showing (hides nav bar).
    private var isShowingLaunchScreen: Bool {
        // Never show launch screen in Nearby Mode — go straight to Nearby Mode content
        if AuthService.shared.isOfflineMode || !networkMonitor.isOnline { return false }
        if !LaunchStateResolver.isReady { return true }
        if surface.isLoading && surface.isEmpty && !eventJoin.isEventJoined && feedService.feedItems.isEmpty { return true }
        return false
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                // Gate rendering until launch state is stable.
                // In Nearby Mode, skip the gate — render immediately.
                if AuthService.shared.isOfflineMode || !networkMonitor.isOnline {
                    surfaceContent
                } else if !LaunchStateResolver.isReady {
                    ScrollView { launchResolvingState.frame(maxWidth: .infinity) }
                } else if surface.isLoading && surface.isEmpty && !eventJoin.isEventJoined && feedService.feedItems.isEmpty {
                    ScrollView { launchResolvingState.frame(maxWidth: .infinity) }
                } else {
                    surfaceContent
                }

                if isOpeningConversation {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        Text("Opening conversation…")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .navigationTitle("Nearify")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(isShowingLaunchScreen ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: FeedRoute.self) { route in
                switch route {
                case .profileDetail(let profileId):
                    FeedProfileDetailView(profileId: profileId)
                }
            }
            .refreshable {
                feedService.requestRefresh(reason: "home-pull")
                meetSuggestion.requestRefresh(reason: "home-pull")
                try? await Task.sleep(nanoseconds: 500_000_000)
                surface.requestRefresh(reason: "home-pull")
            }
            .onAppear {
                feedService.requestRefresh(reason: "home-appear")
                surface.requestRefresh(reason: "home-appear")
                relationshipMemory.requestRefresh(reason: "home-appear")
                meetSuggestion.requestRefresh(reason: "home-appear")

                // Start Nearby Mode tracking if offline
                if AuthService.shared.isOfflineMode || !NetworkMonitor.shared.isOnline {
                    NearbyModeTracker.shared.startTracking()
                }
            }
            .onChange(of: eventJoin.isEventJoined) { wasJoined, isNowJoined in
                if !wasJoined && isNowJoined {
                    // New event join — activate arrival brief
                    let newEventId = eventJoin.currentEventID
                    if newEventId != arrivalBriefEventId {
                        arrivalBriefPending = true
                        hasSeenArrivalBrief = false
                        arrivalBriefEventId = newEventId
                        #if DEBUG
                        print("[ArrivalBrief] pending=true — new event session: \(newEventId ?? "nil")")
                        #endif
                    }
                }
                if wasJoined && !isNowJoined {
                    // Event exit — clear arrival brief state and refresh data
                    arrivalBriefPending = false
                    if targetIntent.isActive {
                        targetIntent.clear(reason: "event left — target intent cleared")
                    }
                    #if DEBUG
                    print("[ArrivalBrief] pending=false — event left")
                    #endif
                    feedService.requestRefresh(reason: "event-left")
                    surface.requestRefresh(reason: "event-left")
                    relationshipMemory.requestRefresh(reason: "event-left")
                }
            }
            .sheet(item: $activeConversation) { dest in
                ConversationView(
                    targetProfileId: dest.targetProfileId,
                    preloadedConversation: dest.conversation,
                    preloadedName: dest.targetName
                )
            }
            .alert("Can't message yet", isPresented: $showNotConnectedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Connect with this person first to start a conversation.")
            }
            .alert("Not detectable right now", isPresented: $showStaleAttendeeAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(staleAttendeeName) is no longer detectable nearby. They may have left or moved out of range.")
            }
            .sheet(item: $findAttendeeDestination) { destination in
                FindAttendeeView(
                    attendee: destination.attendee,
                    connectionMode: destination.connectionMode
                )
            }
            .sheet(isPresented: $showSoloState) {
                SoloStateView(
                    eventName: eventJoin.currentEventName ?? "the event",
                    onDismiss: { showSoloState = false }
                )
                .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(
                    selectedTab: $selectedTab,
                    onSuccess: { eventId in
                        showScanner = false
                        feedService.requestRefresh(reason: "scan-join-success")
                        surface.requestRefresh(reason: "scan-join-success")
                    },
                    onCancel: {
                        showScanner = false
                    }
                )
            }
            .fullScreenCover(isPresented: $showWrapUp) {
                WrapUpFlowView(
                    eventName: eventJoin.currentEventName ?? "Event"
                ) {
                    guard !isWrappingUpEvent else { return }
                    isWrappingUpEvent = true
                    defer { isWrappingUpEvent = false }

                    await eventJoin.leaveEvent()
                    showWrapUp = false
                }
            }
            .sheet(isPresented: $showBriefSheet) {
                NavigationStack {
                    ScrollView {
                        let crowdState = EventCrowdStateResolver.current
                        let brief = EventBriefBuilder.build(crowdState: crowdState)
                        if !brief.isEmpty {
                            ArrivalBriefView(
                                eventName: eventJoin.currentEventName ?? "Event",
                                brief: brief,
                                onTapProfile: { profileId in
                                    showBriefSheet = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        handleViewProfile(profileId: profileId)
                                    }
                                },
                                onDismiss: {
                                    showBriefSheet = false
                                }
                            )
                        }
                    }
                    .background(Color.black.ignoresSafeArea())
                    .navigationTitle("Event Brief")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showBriefSheet = false }
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Surface Content

    private var surfaceContent: some View {
        // ── RENDER SNAPSHOT ──
        // All major derived values computed once per render pass.
        // Sub-branches reference these locals instead of re-calling builders.
        let decision = DecisionResolver.resolve()
        let crowdState = EventCrowdStateResolver.current
        let isLiveEvent = eventJoin.isEventJoined && decision.type == .liveInteraction
        let isArrivalPhase = arrivalBriefPending && !hasSeenArrivalBrief

        // Live event snapshot — computed once, used by all sections
        let surface: DecisionSurface? = isLiveEvent
            ? DecisionSurfaceAdapter.buildDecisionSurface()
            : nil

        let myId = AuthService.shared.currentUser?.id
        let liveAttendees: [EventAttendee] = isLiveEvent
            ? attendeesService.attendees.filter { $0.id != myId && $0.isHereNow }
            : []

        // Brief snapshot — computed once, used by both arrival and normal mode
        let brief: EventBrief? = (isLiveEvent && crowdState != .empty)
            ? EventBriefBuilder.build(crowdState: crowdState)
            : nil

        let isFullyEngaged = surface?.primary.map {
            $0.interactionState == .met
        } ?? false

        let eventName = eventJoin.currentEventName ?? "Event"

        #if DEBUG
        let _ = {
            if isLiveEvent {
                let primaryName = surface?.primary?.name ?? "none"
                let briefTarget = brief?.startHere.first?.name ?? "none"
                print("[RenderSnapshot] crowd=\(crowdState.rawValue) primary=\(primaryName) briefTarget=\(briefTarget) arrival=\(isArrivalPhase) engaged=\(isFullyEngaged)")
            }
        }()
        #endif

        return ScrollView {
            VStack(spacing: 0) {
                // Nearby Mode experience — replaces normal content when offline.
                // Check both isOfflineMode (auth-level state) and !isOnline (network-level)
                // to ensure immediate transition when network drops mid-session.
                if AuthService.shared.isOfflineMode || !networkMonitor.isOnline {
                    nearbyModeContent
                } else if isLiveEvent, let surface {

                    Spacer().frame(height: 24)

                    // ── ARRIVAL BRIEF (one-time, dominant during arrival phase) ──
                    if isArrivalPhase {
                        if let brief, !brief.isEmpty {
                            #if DEBUG
                            let _ = print("[ArrivalBrief] RENDERED — startHere=\(brief.startHere.count) hereNow=\(brief.hereNow.count) likely=\(brief.likelyAttendees.count) suggested=\(brief.suggestedConnections.count) points=\(brief.talkingPoints.count)")
                            #endif

                            ArrivalBriefView(
                                eventName: eventName,
                                brief: brief,
                                onTapProfile: { profileId in
                                    dismissArrivalBrief(reason: "continue tap from brief")
                                    handleFindAttendee(profileId: profileId, source: .brief)
                                },
                                onDismiss: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        dismissArrivalBrief(reason: "user tapped Got it")
                                    }
                                }
                            )

                            sayGoodbyeButton
                        } else {
                            #if DEBUG
                            let _ = print("[ArrivalBrief] suppressed — no content yet (attendees may still be loading)")
                            #endif

                            arrivalWaitingHeader

                            DecisionSurfaceView(
                                surface: surface,
                                crowdState: crowdState,
                                liveAttendees: liveAttendees,
                                onAction: { personId, actionType in
                                    handleSurfaceAction(personId: personId, action: actionType)
                                },
                                onViewProfile: { profileId in
                                    handleViewProfile(profileId: profileId)
                                }
                            )
                            .padding(.horizontal)

                            sayGoodbyeButton
                        }
                    } else {
                        // ── NORMAL MODE (post-arrival) ──

                        // Event Brief (ongoing, lighter) — reuses snapshot
                        if hasSeenArrivalBrief && !isFullyEngaged {
                            if let brief, !brief.isEmpty {
                                EventBriefView(
                                    brief: brief,
                                    onTapProfile: { profileId in
                                        handleFindAttendee(profileId: profileId, source: .brief)
                                    }
                                )
                            }
                        }

                        // Decision Surface (persistent action layer)
                        DecisionSurfaceView(
                            surface: surface,
                            crowdState: crowdState,
                            liveAttendees: liveAttendees,
                            onAction: { personId, actionType in
                                handleSurfaceAction(personId: personId, action: actionType)
                            },
                            onViewProfile: { profileId in
                                handleViewProfile(profileId: profileId)
                            }
                        )
                        .padding(.horizontal)

                        sayGoodbyeButton
                    }

                } else {
                    decisionHero(decision)
                }
            }
            .padding(.top, DesignTokens.titleToContent)
            .padding(.bottom, DesignTokens.sectionSpacing)
        }
    }

    // MARK: - Nearby Mode Content

    /// Full Nearby Mode experience — shown when app is in offline mode.
    /// Replaces the normal feed/event surface with BLE-powered local discovery.
    private var nearbyModeContent: some View {
        let activeCount = nearbyTracker.activeEncounters.count
        let recentCount = nearbyTracker.recentEncounters.count

        #if DEBUG
        let _ = print("[NearbyMode] rendering home from BLE/local presence")
        let _ = print("[NearbyMode] visible nearby users: \(activeCount) active, \(recentCount) recent")
        #endif

        return VStack(spacing: 20) {
            Spacer().frame(height: 8)

            // Status card
            NearbyModeCardView()

            // People Nearby + Seen Nearby sections
            NearbyPeopleSectionView { encounter in
                handleNearbyFind(encounter)
            }

            // Gated actions reminder
            VStack(spacing: 8) {
                gatedFeatureRow(icon: "bubble.left", label: "Messaging", detail: "Available when connected")
                gatedFeatureRow(icon: "person.badge.plus", label: "Connect", detail: "Available when connected")
                gatedFeatureRow(icon: "calendar", label: "Event Join", detail: "Available when connected")
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func gatedFeatureRow(icon: String, label: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.15))
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.25))

            Spacer()

            Text(detail)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.15))
        }
        .padding(.vertical, 4)
    }

    /// Handles the Find action from a Nearby Mode encounter.
    private func handleNearbyFind(_ encounter: NearbyModeTracker.LocalEncounter) {
        let prefix = encounter.id
        let profileId = encounter.profileId ?? UUID()
        let attendee = ProfileCache.shared.offlineAttendee(forPrefix: prefix, profileId: profileId)

        // Check if BLE signal is still active
        let hasBLE = BLEScannerService.shared.getFilteredDevices().contains { device in
            BLEAdvertiserService.parseCommunityPrefix(from: device.name) == prefix
        }

        if hasBLE {
            presentFindAttendee(attendee: attendee, source: .explore)
        } else {
            staleAttendeeName = encounter.name
            showStaleAttendeeAlert = true
        }
    }

    // MARK: - Arrival Waiting Header
    //
    // Minimal header shown when the arrival brief is pending but attendee
    // data hasn't loaded yet. Auto-dismisses once the user interacts.

    private var arrivalWaitingHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("EVENT BRIEF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.cyan.opacity(0.5))
                    .tracking(0.8)
                Text(eventJoin.currentEventName ?? "Event")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
            ProgressView()
                .tint(.cyan.opacity(0.4))
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Say Goodbye Button

    private var sayGoodbyeButton: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 16)

            // "View Brief" — persistent entry point after arrival brief is dismissed
            if hasSeenArrivalBrief {
                Button {
                    showBriefSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                        Text("View Brief")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.cyan.opacity(0.5))
                }
                .padding(.bottom, 12)
            }

            Button {
                showWrapUp = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.wave")
                    Text("Say Goodbye")
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.4))
            }
            Spacer().frame(height: 24)
        }
    }

    // MARK: - Surface Action Handler

    private func handleSurfaceAction(personId: UUID, action: DecisionActionType) {
        // Any interaction from the Decision Surface dismisses the arrival brief
        dismissArrivalBrief(reason: "surface action: \(action.rawValue)")

        switch action {
        case .goSayHi, .find, .navigate:
            handleFindAttendee(profileId: personId)
        case .followUp:
            handleMessage(profileId: personId)
        case .viewProfile:
            handleViewProfile(profileId: personId)
        }
    }

    // MARK: - Arrival Brief Dismiss

    private func dismissArrivalBrief(reason: String) {
        guard arrivalBriefPending || !hasSeenArrivalBrief else { return }
        arrivalBriefPending = false
        hasSeenArrivalBrief = true
        #if DEBUG
        print("[ArrivalBrief] dismissed — reason: \(reason)")
        #endif
    }

    // MARK: - Decision Hero Block
    //
    // The single decision card. Answers: "What should I do right now?"
    // No stacked cards. No competing actions. No dashboard.

    private func decisionHero(_ decision: PrimaryDecision) -> some View {
        let avatarSize: CGFloat = min(max(UIScreen.main.bounds.width * 0.35, 120), 160)

        return VStack(spacing: 0) {
            Spacer().frame(height: 48)

            // Tappable person area — navigates to People tab with focus
            Group {
                // Person avatar (when decision involves a person)
                if let personName = decision.personName {
                    if let avatarUrl = decision.personAvatarUrl, let url = URL(string: avatarUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: avatarSize, height: avatarSize)
                                    .clipShape(Circle())
                            default:
                                decisionInitialsAvatar(personName, size: avatarSize)
                            }
                        }
                    } else {
                        decisionInitialsAvatar(personName, size: avatarSize)
                    }
                } else {
                    // No person — show contextual icon
                    Image(systemName: decisionIcon(decision.type))
                        .font(.system(size: 48))
                        .foregroundColor(decisionAccentColor(decision.type).opacity(0.8))
                }

                Spacer().frame(height: 24)

                // Headline
                Text(decision.headline)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                // Context line (who they are in relation to me)
                if let contextLine = decision.contextLine {
                    Text(contextLine)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                }

                // Why now line (why this matters right now)
                if let whyNowLine = decision.whyNowLine {
                    Text(whyNowLine)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                // Subtext (fallback for non-person cards)
                if decision.contextLine == nil, let subtext = decision.subtext {
                    Text(subtext)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let personId = decision.personId {
                    NavigationState.shared.peopleFocusTarget = PeopleFocusTarget(
                        profileId: personId,
                        source: "home"
                    )
                    switchTab(to: .people)
                }
            }

            Spacer().frame(height: 32)

            // Primary CTA
            Button {
                handleDecisionAction(decision, isPrimary: true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: decisionPrimaryIcon(decision))
                    Text(decision.primaryAction)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(decisionAccentColor(decision.type))
                .foregroundColor(.black)
                .cornerRadius(14)
            }
            .padding(.horizontal, 32)

            // Support text for solo/waiting state
            if decision.primaryAction == "Preview your network" {
                Text("See who you've met and who to connect with")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.top, 4)
            }

            // Secondary CTA (optional, max one)
            if let secondary = decision.secondaryAction {
                Button {
                    handleDecisionAction(decision, isPrimary: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: decisionSecondaryIcon(decision))
                        Text(secondary)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(.white.opacity(0.7))
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            // "Say Goodbye" — wrap-up action, only during active events
            if eventJoin.isEventJoined, case .liveInteraction = decision.type {
                Button {
                    showWrapUp = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.wave")
                        Text("Say Goodbye")
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 12)
                }
            }

            Spacer().frame(height: 40)
        }
    }

    // MARK: - Decision Helpers

    private func decisionInitialsAvatar(_ name: String, size: CGFloat = 120) -> some View {
        let parts = name.components(separatedBy: " ")
        let initials: String
        if parts.count >= 2 {
            initials = "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        } else {
            initials = String(name.prefix(2)).uppercased()
        }
        return Circle()
            .fill(Color.orange.opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundColor(.orange)
            )
    }

    private func decisionIcon(_ type: DecisionType) -> String {
        switch type {
        case .liveInteraction: return "location.fill"
        case .rejoinEvent:     return "arrow.counterclockwise.circle.fill"
        case .reconnect:       return "person.fill"
        case .meetNew:         return "sparkles"
        case .explore:         return "qrcode.viewfinder"
        }
    }

    private func decisionAccentColor(_ type: DecisionType) -> Color {
        switch type {
        case .liveInteraction: return .green
        case .rejoinEvent:     return .orange
        case .reconnect:       return .cyan
        case .meetNew:         return .cyan
        case .explore:         return .white
        }
    }

    private func decisionPrimaryIcon(_ decision: PrimaryDecision) -> String {
        switch decision.type {
        case .liveInteraction:
            if decision.primaryAction == "Preview your network" { return "person.2" }
            return decision.personName != nil ? "location.fill" : "person.2"
        case .rejoinEvent:     return "arrow.right.circle.fill"
        case .reconnect:       return decision.primaryAction == "Message" ? "bubble.left" : "person.badge.plus"
        case .meetNew:         return "location.fill"
        case .explore:         return "camera.fill"
        }
    }

    private func decisionSecondaryIcon(_ decision: PrimaryDecision) -> String {
        switch decision.secondaryAction {
        case "View profile":        return "person"
        case "Browse Events":       return "safari"
        case "Different event":     return "qrcode"
        case "Preview your network": return "person.2"
        case "View everyone":       return "person.3"
        default:                    return "chevron.right"
        }
    }

    // MARK: - Decision Action Routing

    private func handleDecisionAction(_ decision: PrimaryDecision, isPrimary: Bool) {
        switch decision.type {
        case .liveInteraction:
            if isPrimary {
                if decision.primaryAction == "Preview your network" {
                    // Empty state → inject event context and navigate to People tab.
                    if let eventId = decision.eventId, let eventName = decision.eventName {
                        NavigationState.shared.eventContext = PeopleEventContext(
                            eventId: eventId, eventName: eventName
                        )
                    }
                    switchTab(to: .people)
                    return
                }
                // "Find them" — find the specific person
                handlePeopleCTA(specificPersonId: decision.personId)
            } else {
                switch decision.secondaryAction {
                case "Preview your network":
                    // Early state secondary → inject event context and go to People tab
                    if let eventId = decision.eventId, let eventName = decision.eventName {
                        NavigationState.shared.eventContext = PeopleEventContext(
                            eventId: eventId, eventName: eventName
                        )
                    }
                    switchTab(to: .people)
                case "View everyone":
                    // Active state secondary → Event tab (full attendee list)
                    switchTab(to: .event)
                default:
                    if let personId = decision.personId {
                        handleViewProfile(profileId: personId)
                    }
                }
            }

        case .rejoinEvent:
            if isPrimary {
                if let eventId = decision.eventId {
                    Task { await eventJoin.joinEvent(eventID: eventId) }
                }
            } else {
                switchTab(to: .event)
            }

        case .reconnect:
            if isPrimary {
                if let personId = decision.personId {
                    if decision.primaryAction == "Message" {
                        handleMessage(profileId: personId)
                    } else {
                        handleConnect(profileId: personId)
                    }
                }
            } else {
                if let personId = decision.personId {
                    handleViewProfile(profileId: personId)
                }
            }

        case .meetNew:
            if isPrimary {
                if let personId = decision.personId {
                    handleFindAttendee(profileId: personId)
                }
            } else {
                if let personId = decision.personId {
                    handleViewProfile(profileId: personId)
                }
            }

        case .explore:
            if isPrimary {
                showScanner = true
            } else {
                switchTab(to: .event)
            }
        }
    }

    // MARK: - Event Context Strip

    private func eventContextStrip(eventName: String, attendeeCount: Int) -> some View {
        return HStack(spacing: 8) {
            Circle()
                .fill(UserPresenceStateResolver.statusColor)
                .frame(width: 6, height: 6)
            Text(eventName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.9))
            if let qualifier = UserPresenceStateResolver.homePresenceQualifier {
                Text("·")
                    .foregroundColor(.gray)
                Text(qualifier)
                    .font(.caption)
                    .foregroundColor(.green.opacity(0.8))
            }
            if attendeeCount > 0 {
                Text("·")
                    .foregroundColor(.gray)
                Text("\(attendeeCount) nearby")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Continue Section (Featured Arrival + Standard)

    /// Renders the Continue section. The top-priority arrival/find item is
    /// promoted into the hero block above, so it's excluded here to avoid
    /// showing the same person twice. Remaining items render as standard cards.
    private var continueSectionView: some View {
        let items = surface.continueItems
        let accentColor: Color = .orange

        // The featured arrival is rendered in the hero — exclude it here
        let featuredId = featuredArrivalItem?.id
        let remainingItems = items.filter { $0.id != featuredId }

        return Group {
            if !remainingItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: HomeSurfaceSection.continue.icon)
                            .font(.caption)
                            .foregroundColor(accentColor)
                        Text(HomeSurfaceSection.continue.title.uppercased())
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(accentColor)
                            .tracking(1.2)
                    }
                    .padding(.horizontal)

                    ForEach(remainingItems) { item in
                        surfaceCard(item, accentColor: accentColor)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: - Section View

    private func sectionView(
        section: HomeSurfaceSection,
        items: [HomeSurfaceItem],
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.caption)
                    .foregroundColor(accentColor)
                Text(section.title.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(accentColor)
                    .tracking(1.2)
            }
            .padding(.horizontal)

            ForEach(items) { item in
                surfaceCard(item, accentColor: accentColor)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Surface Card (with avatar)

    private func surfaceCard(_ item: HomeSurfaceItem, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Avatar thumbnail
                if item.profileId != nil {
                    SurfaceThumbnailView(
                        avatarUrl: item.avatarUrl,
                        name: item.name,
                        accentColor: accentColor
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.headline)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let profileId = item.profileId {
                    NavigationState.shared.peopleFocusTarget = PeopleFocusTarget(
                        profileId: profileId,
                        source: "home"
                    )
                    switchTab(to: .people)
                }
            }

            HStack(spacing: 12) {
                surfaceActionButton(item, accentColor: accentColor)

                if item.isFind, item.profileId != nil {
                    FeedActionButton(
                        title: "View Profile",
                        icon: "person",
                        color: .white.opacity(0.7),
                        action: { handleAction(item, override: .viewProfile) }
                    )
                }
            }
            .padding(.top, 10)
        }
        .feedCard()
        .overlay(
            item.section == .continue ?
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accentColor.opacity(0.3), lineWidth: 1)
                : nil
        )
    }

    private func surfaceActionButton(_ item: HomeSurfaceItem, accentColor: Color) -> some View {
        let icon: String
        switch item.actionType {
        case .findAttendee: icon = item.actionLabel == "Go say hi" ? "hand.wave" : "location"
        case .reply:        icon = "arrowshape.turn.up.left"
        case .followUp:     icon = "bubble.left"
        case .message:      icon = "bubble.left"
        case .connect:      icon = "person.badge.plus"
        case .jumpBack:     icon = "arrow.right.circle"
        case .viewProfile:  icon = "person"
        }

        return FeedActionButton(
            title: item.actionLabel,
            icon: icon,
            color: accentColor,
            action: { handleAction(item) }
        )
    }

    // MARK: - Briefing Block (Data-Driven)

    private var briefingBlock: some View {
        Group {
            switch homePresentation {
            case .liveEvent(let featured, _):
                liveEventBriefing(featured: featured)

            case .eventContinuation(let suggestion, let person):
                eventContinuationBlock(suggestion: suggestion, person: person)

            case .personContinuation(let person):
                personContinuationBlock(person: person)

            case .joining:
                joiningStatusBlock

            case .onboarding:
                firstEventBlock
            }
        }
    }

    /// Live event briefing — person-led hero when featured arrival exists,
    /// otherwise generic hero. Collapses when feed items are plentiful
    /// and no featured person needs highlighting.
    /// When a target intent is active (from "Rejoin to find them"), shows
    /// targeted guidance instead of the generic briefing.
    @ViewBuilder
    private func liveEventBriefing(featured: HomeSurfaceItem?) -> some View {
        if targetIntent.isActive {
            targetedGuidanceBlock
        } else if let featured = featured {
            joinedBriefingBlock(featured: featured)
        } else if !surface.isEmpty {
            EmptyView()
        } else {
            joinedBriefingBlock(featured: nil)
        }
    }

    // MARK: - Best Present Alternative

    /// Selects the best currently present person from the live attendee list.
    private var bestPresentAlternative: EventAttendee? {
        let attendees = attendeesService.attendees
        let myId = AuthService.shared.currentUser?.id
        let targetId = targetIntent.targetProfileId

        let candidates = attendees.filter { a in
            a.id != myId && a.id != targetId
        }

        guard !candidates.isEmpty else { return nil }

        let encounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds

        // Score each candidate
        let scored = candidates.map { attendee -> (EventAttendee, Double) in
            var score: Double = 0

            // Encounter overlap (strongest signal)
            if let tracker = encounters[attendee.id] {
                score += min(Double(tracker.totalSeconds) / 60.0, 10.0) * 3.0
            }

            // Connected (prior relationship)
            if connectedIds.contains(attendee.id) {
                score += 5.0
            }

            // Active now (recency)
            if attendee.isActiveNow {
                score += 2.0
            }

            return (attendee, score)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    /// Builds a one-line explanation for why the alternative is suggested.
    private func alternativeExplanation(for attendee: EventAttendee) -> String {
        let encounters = EncounterService.shared.activeEncounters
        let connectedIds = AttendeeStateResolver.shared.connectedIds

        if let tracker = encounters[attendee.id], tracker.totalSeconds >= 60 {
            let mins = tracker.totalSeconds / 60
            return "You've spent \(mins) minute\(mins == 1 ? "" : "s") nearby — strong interaction signal."
        }

        if connectedIds.contains(attendee.id) {
            return "You're already connected and they're active right now."
        }

        if attendee.isActiveNow {
            return "They're currently active at this event."
        }

        return "They're here now."
    }

    // MARK: - Targeted Guidance Block

    /// Routes to the correct view based on resolution state.
    private var targetedGuidanceBlock: some View {
        VStack(spacing: 16) {
            switch targetIntent.resolution {
            case .resolving:
                targetSearchingView

            case .found:
                targetFoundView

            case .notPresent:
                targetNotPresentCard

            case .waiting:
                targetWaitingView
            }
        }
        .onAppear {
            #if DEBUG
            print("[TargetResolution] started for target: \(targetIntent.targetName ?? "unknown")")
            #endif
        }
    }

    // MARK: - Resolving State

    private var targetSearchingView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 20)

            ProgressView()
                .tint(.cyan)
                .scaleEffect(1.1)

            Text("Looking for \(targetIntent.targetFirstName)…")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text("Checking who's here right now")
                .font(.subheadline)
                .foregroundColor(.gray)

            Spacer().frame(height: 20)
        }
    }

    // MARK: - Target Found

    private var targetFoundView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 20)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.cyan)

            Text("\(targetIntent.targetFirstName) is here")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            HStack(spacing: 12) {
                FeedActionButton(
                    title: "Go say hi",
                    icon: "hand.wave",
                    color: .cyan,
                    action: {
                        guard let targetId = targetIntent.targetProfileId else { return }
                        #if DEBUG
                        print("[TargetResolution] attendee match found: \(targetIntent.targetName ?? "unknown")")
                        #endif
                        handleFindAttendee(profileId: targetId)
                        targetIntent.clear(reason: "acted on → Go say hi")
                    }
                )

                FeedActionButton(
                    title: "View Profile",
                    icon: "person",
                    color: .white.opacity(0.7),
                    action: {
                        guard let targetId = targetIntent.targetProfileId else { return }
                        handleViewProfile(profileId: targetId)
                        targetIntent.clear(reason: "acted on → View Profile")
                    }
                )
            }

            Spacer().frame(height: 20)
        }
    }

    // MARK: - Target Not Present (Fallback Card)

    private var targetNotPresentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Headline
            VStack(alignment: .leading, spacing: 6) {
                Text("\(targetIntent.targetFirstName) is not here right now")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("You rejoined to find \(targetIntent.targetName ?? "them"), but they're not currently active at this event.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(18)

            // Alternative person section
            if let alternative = bestPresentAlternative {
                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("HERE NOW")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.cyan.opacity(0.7))
                        .tracking(0.8)

                    HStack(spacing: 12) {
                        // Avatar
                        alternativeAvatar(alternative)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(alternative.name)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)

                            Text(alternativeExplanation(for: alternative))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        FeedActionButton(
                            title: "Find \(firstName(alternative.name))",
                            icon: "hand.wave",
                            color: .cyan,
                            action: {
                                #if DEBUG
                                print("[TargetResolution] switched to alternative: \(alternative.name)")
                                #endif
                                targetIntent.set(profileId: alternative.id, name: alternative.name)
                                targetIntent.markFound()
                            }
                        )

                        FeedActionButton(
                            title: "Keep waiting",
                            icon: "clock",
                            color: .white.opacity(0.6),
                            action: {
                                targetIntent.markWaiting()
                            }
                        )

                        FeedActionButton(
                            title: "Dismiss",
                            icon: "xmark",
                            color: .white.opacity(0.4),
                            action: {
                                targetIntent.clear(reason: "dismissed by user")
                            }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            } else {
                // No alternative available — simpler card
                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("No one else is active right now.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack(spacing: 10) {
                        FeedActionButton(
                            title: "Keep waiting",
                            icon: "clock",
                            color: .white.opacity(0.6),
                            action: {
                                targetIntent.markWaiting()
                            }
                        )

                        FeedActionButton(
                            title: "Dismiss",
                            icon: "xmark",
                            color: .white.opacity(0.4),
                            action: {
                                targetIntent.clear(reason: "dismissed by user")
                            }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Keep Waiting State

    private var targetWaitingView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 16)

            Image(systemName: "eye")
                .font(.system(size: 24))
                .foregroundColor(.cyan.opacity(0.6))

            Text("Watching for \(targetIntent.targetFirstName)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.8))

            Text("We'll let you know when they arrive")
                .font(.caption)
                .foregroundColor(.gray)

            Button {
                targetIntent.clear(reason: "dismissed from waiting state")
            } label: {
                Text("Stop waiting")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.top, 2)

            Spacer().frame(height: 16)
        }
    }

    // MARK: - Target Helpers

    private func alternativeAvatar(_ attendee: EventAttendee) -> some View {
        Group {
            if let urlStr = attendee.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36).clipShape(Circle())
                    default:
                        targetInitialsCircle(attendee.name)
                    }
                }
            } else {
                targetInitialsCircle(attendee.name)
            }
        }
        .frame(width: 36, height: 36)
    }

    private func targetInitialsCircle(_ name: String) -> some View {
        Circle()
            .fill(Color.cyan.opacity(0.2))
            .overlay(
                Text(initials(from: name))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan)
            )
    }

    private func initials(from name: String) -> String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    /// Event continuation block — wraps eventContextCard with spacing.
    private func eventContinuationBlock(suggestion: EventSuggestion, person: RelationshipMemory?) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)
            eventContextCard(suggestion)

            // Post-event summary — shown after leaving or going dormant
            if let summary = eventJoin.postEventSummary, !summary.isEmpty {
                PostEventSummaryView(
                    summary: summary,
                    onMessage: { profileId in handleMessage(profileId: profileId) },
                    onViewProfile: { profileId in handleViewProfile(profileId: profileId) }
                )
                .feedCard()
                .padding(.horizontal)
            }

            Spacer().frame(height: 24)
        }
    }

    /// Person continuation block — person card + scan fallback.
    private func personContinuationBlock(person: RelationshipMemory) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)
            continueWithPersonCard(person)
            noEventFallback
            Spacer().frame(height: 24)
        }
    }

    // MARK: - Event Context Card

    /// Primary Home card when not in an event. The event is the anchor;
    /// people are nested actions within that context.
    private func eventContextCard(_ suggestion: EventSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Event header ──
            VStack(alignment: .leading, spacing: 6) {
                Text("Back at \(suggestion.eventName)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text(suggestion.contextLine)
                    .font(.subheadline)
                    .foregroundColor(.gray)

                // Event actions
                HStack(spacing: 10) {
                    if let eventId = suggestion.eventId {
                        Button {
                            Task { await eventJoin.joinEvent(eventID: eventId) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.caption)
                                Text("Rejoin")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .foregroundColor(.black)
                            .cornerRadius(8)
                        }
                    }

                    Button {
                        showScanner = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "qrcode")
                                .font(.caption)
                            Text("Different event")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white.opacity(0.6))
                        .cornerRadius(8)
                    }
                }
                .padding(.top, 4)

                Text("Pick up where you left off")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 6)
            }
            .padding(18)

            // ── People nested under event ──
            if let person = continueWithPersonCandidate {
                Divider()
                    .background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("RECONNECT WITH")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange.opacity(0.7))
                        .tracking(0.8)

                    HStack(spacing: 12) {
                        SurfaceThumbnailView(
                            avatarUrl: person.avatarUrl,
                            name: person.name,
                            accentColor: .orange
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name.components(separatedBy: " ").first ?? person.name)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)

                            Text(continuePersonPrimaryLine(person))
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))

                            let secondary = continuePersonSecondaryLine(person)
                            if !secondary.isEmpty {
                                Text(secondary)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        FeedActionButton(
                            title: "Message",
                            icon: "bubble.left",
                            color: .orange,
                            action: { handleMessage(profileId: person.profileId) }
                        )

                        FeedActionButton(
                            title: "View Profile",
                            icon: "person",
                            color: .white.opacity(0.7),
                            action: { handleViewProfile(profileId: person.profileId) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            // ── Meet Next — expand intentionally ──
            if let meetNext = meetNextCandidate(excludingReconnect: continueWithPersonCandidate?.profileId) {
                Divider()
                    .background(Color.white.opacity(0.08))

                meetNextSection(meetNext, rejoinEventId: suggestion.eventId)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Meet Next Section

    /// Renders the "MEET NEXT" row inside the event card.
    /// CTA is context-aware:
    ///   - Non-event: "Rejoin to find them" → rejoins event
    ///   - Live event: "Go say hi" → radar/find attendee
    private func meetNextSection(_ candidate: MeetNextCandidate, rejoinEventId: String?) -> some View {
        let isLive = eventJoin.isEventJoined

        return VStack(alignment: .leading, spacing: 10) {
            Text("MEET NEXT")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.cyan.opacity(0.7))
                .tracking(0.8)

            HStack(spacing: 12) {
                meetNextAvatar(candidate)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name.components(separatedBy: " ").first ?? candidate.name)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text(candidate.explanation)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                if isLive {
                    // Live event — route to radar / find attendee
                    FeedActionButton(
                        title: "Go say hi",
                        icon: "hand.wave",
                        color: .cyan,
                        action: {
                            #if DEBUG
                            print("[MeetNextCTA] live-event -> radar target: \(candidate.name)")
                            #endif
                            handleFindAttendee(profileId: candidate.profileId)
                        }
                    )
                } else if let eventId = rejoinEventId {
                    // Non-event with rejoinable event — rejoin then find
                    FeedActionButton(
                        title: "Rejoin to find them",
                        icon: "arrow.right.circle",
                        color: .cyan,
                        action: {
                            #if DEBUG
                            print("[MeetNextCTA] non-event -> rejoin target: \(candidate.name)")
                            #endif
                            targetIntent.set(profileId: candidate.profileId, name: candidate.name)
                            Task { await eventJoin.joinEvent(eventID: eventId) }
                        }
                    )
                }

                FeedActionButton(
                    title: "View Profile",
                    icon: "person",
                    color: .white.opacity(0.7),
                    action: { handleViewProfile(profileId: candidate.profileId) }
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func meetNextAvatar(_ candidate: MeetNextCandidate) -> some View {
        Group {
            if let urlStr = candidate.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    default:
                        meetNextInitials(candidate.name)
                    }
                }
            } else {
                meetNextInitials(candidate.name)
            }
        }
        .frame(width: 36, height: 36)
    }

    private func meetNextInitials(_ name: String) -> some View {
        let parts = name.components(separatedBy: " ")
        let initials = parts.count >= 2
            ? "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            : String(name.prefix(2)).uppercased()
        return Circle()
            .fill(Color.cyan.opacity(0.2))
            .overlay(
                Text(initials)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan)
            )
    }

    /// Fallback when history exists but no event suggestion is available.
    private var noEventFallback: some View {
        VStack(spacing: 12) {
            Text("Join an event to start meeting people")
                .font(.subheadline)
                .foregroundColor(.gray)

            Button {
                showScanner = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.caption)
                    Text("Scan Event QR")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    /// First-time user block — clean onboarding when no history exists.
    /// Matches LaunchState.signedInNoHistory.
    /// Single coherent narrative: "Join an event to get started."
    private var firstEventBlock: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 52))
                .foregroundColor(.white.opacity(0.3))

            Text("Join an event to get started")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text("Scan an event QR or browse events nearby.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button {
                    showScanner = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                        Text("Scan Event QR")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .cornerRadius(14)
                }

                Button {
                    switchTab(to: .event)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "safari")
                        Text("Browse Events")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(.white.opacity(0.7))
                    .cornerRadius(14)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)

            Spacer().frame(height: 24)
        }
    }

    // MARK: - Event Suggestion Logic

    /// Lightweight event suggestion derived from existing feed + relationship data.
    private struct EventSuggestion {
        let eventName: String
        let eventId: String?
        let peopleMet: Int
        let isRejoinable: Bool
        let contextLine: String
    }

    /// Selects ONE best event suggestion from existing data.
    /// Priority: rejoinable event (highest) → relationship strength → interaction density.
    /// Reads through @ObservedObject properties so SwiftUI re-evaluates when data arrives.
    private var bestEventSuggestion: EventSuggestion? {
        let feedItems = feedService.feedItems
        let relationships = relationshipMemory.relationships

        #if DEBUG
        print("[HomeUI] bestEventSuggestion evaluating — feedItems: \(feedItems.count), relationships: \(relationships.count)")
        #endif

        var eventStats: [String: (people: Set<UUID>, mostRecent: Date, eventId: UUID?)] = [:]

        for item in feedItems {
            guard let name = item.metadata?.eventName, !name.isEmpty else { continue }
            var entry = eventStats[name] ?? (people: Set(), mostRecent: .distantPast, eventId: nil)
            if let actorId = item.actorProfileId {
                entry.people.insert(actorId)
            }
            if let ts = item.createdAt, ts > entry.mostRecent {
                entry.mostRecent = ts
                if let eid = item.eventId { entry.eventId = eid }
            }
            eventStats[name] = entry
        }

        for rel in relationships {
            for eventName in rel.eventContexts {
                var entry = eventStats[eventName] ?? (people: Set(), mostRecent: .distantPast, eventId: nil)
                entry.people.insert(rel.profileId)
                eventStats[eventName] = entry
            }
        }

        guard !eventStats.isEmpty else {
            #if DEBUG
            print("[EventSuggestion] None available — no events in feed or relationships")
            #endif
            return nil
        }

        let reconnect = eventJoin.reconnectContext

        // --- Priority sort ---
        // 1. Rejoinable event always wins (user can actually act on it)
        // 2. Among non-rejoinable: strongest relationships first, then recency
        let ranked = eventStats.sorted { a, b in
            let aRejoinable = reconnect?.eventName == a.key
            let bRejoinable = reconnect?.eventName == b.key

            // Rejoinable always beats non-rejoinable
            if aRejoinable != bRejoinable { return aRejoinable }

            // Among equals: relationship strength (people count as proxy)
            if a.value.people.count != b.value.people.count {
                return a.value.people.count > b.value.people.count
            }

            // Final tiebreak: most recent activity
            return a.value.mostRecent > b.value.mostRecent
        }

        guard let best = ranked.first else { return nil }

        let isRejoinable = reconnect?.eventName == best.key
        let rejoinId = isRejoinable ? reconnect?.eventId : best.value.eventId?.uuidString
        let count = best.value.people.count
        let context = count > 0
            ? "You met \(count) \(count == 1 ? "person" : "people") there"
            : "You were there recently"

        #if DEBUG
        let source = isRejoinable ? "rejoinable-priority" : "interaction-density"
        print("[EventSuggestion] Selected: \(best.key) (source: \(source), people: \(count), rejoinable: \(isRejoinable))")
        if let fallback = ranked.dropFirst().first {
            let fbSource = reconnect?.eventName == fallback.key ? "rejoinable-priority" : "interaction-density"
            print("[EventSuggestion] Fallback: \(fallback.key) (source: \(fbSource))")
        }
        #endif

        return EventSuggestion(
            eventName: best.key, eventId: rejoinId,
            peopleMet: count, isRejoinable: isRejoinable, contextLine: context
        )
    }

    // MARK: - Empty State Helpers

    /// Selects ONE best candidate for "Continue with Person" from existing
    /// RelationshipMemoryService data. Priority:
    /// 1. Needs follow-up (strong interaction, no recent message)
    /// 2. Strongest recent relationship (within 7 days)
    /// Returns nil if no meaningful candidate exists.
    private var continueWithPersonCandidate: RelationshipMemory? {
        let relationships = relationshipMemory.relationships
        guard !relationships.isEmpty else { return nil }

        let sevenDays: TimeInterval = 7 * 86400

        // Priority 1: needs follow-up (already computed by RelationshipMemoryService)
        let followUpCandidates = relationships.filter { r in
            r.needsFollowUp && isRecentEnough(r, within: sevenDays)
        }
        if let best = followUpCandidates.max(by: { $0.relationshipStrength < $1.relationshipStrength }) {
            return best
        }

        // Priority 2: strongest recent relationship
        let recentStrong = relationships.filter { r in
            isRecentEnough(r, within: sevenDays) &&
            (r.totalOverlapSeconds >= 300 || r.encounterCount >= 2 || r.connectionStatus == .accepted)
        }
        if let best = recentStrong.max(by: { $0.relationshipStrength < $1.relationshipStrength }) {
            return best
        }

        return nil
    }

    // MARK: - Meet Next Candidate

    /// Lightweight model for the "Meet Next" suggestion inside the event card.
    private struct MeetNextCandidate {
        let profileId: UUID
        let name: String
        let avatarUrl: String?
        let explanation: String
    }

    /// Selects ONE best "Meet Next" candidate from relationship memory.
    /// Excludes: current user, reconnect person.
    /// Tiered selection:
    ///   1. New/weak connections with strong signal (discovery)
    ///   2. Strong connections worth deepening (high interaction)
    ///   3. Any remaining person not already in RECONNECT
    /// Returns nil only if no other users exist or the only relationship is the reconnect person.
    private func meetNextCandidate(excludingReconnect reconnectId: UUID?) -> MeetNextCandidate? {
        let relationships = relationshipMemory.relationships
        guard let currentUser = AuthService.shared.currentUser else { return nil }

        let myInterests = Set((currentUser.interests ?? []).map { $0.lowercased() })
        let mySkills = Set((currentUser.skills ?? []).map { $0.lowercased() })

        // Filter to eligible candidates (exclude self + reconnect person)
        let eligible = relationships.filter { rel in
            rel.profileId != currentUser.id && rel.profileId != reconnectId
        }

        guard !eligible.isEmpty else {
            #if DEBUG
            print("[MeetNext] No eligible candidates (total: \(relationships.count), excluded: self + reconnect)")
            #endif
            return nil
        }

        // --- Tier 1: New/weak connections (not accepted, or accepted but no conversation) ---
        let tier1 = eligible.filter { rel in
            rel.connectionStatus != .accepted || !rel.hasConversation
        }

        // --- Tier 2: Strong connections worth deepening (accepted + conversation) ---
        let tier2 = eligible.filter { rel in
            rel.connectionStatus == .accepted && rel.hasConversation
        }

        // Try Tier 1 first, then Tier 2
        let tiers: [(candidates: [RelationshipMemory], label: String)] = [
            (tier1, "new-connection"),
            (tier2, "deepen-connection"),
        ]

        for tier in tiers {
            guard !tier.candidates.isEmpty else { continue }

            if let result = bestFromTier(
                tier.candidates,
                tierLabel: tier.label,
                myInterests: myInterests,
                mySkills: mySkills
            ) {
                return result
            }
        }

        // --- Tier 3: Absolute fallback — pick anyone eligible ---
        // Sort by interaction time descending (strongest signal = most worth showing)
        let fallback = eligible.max(by: { $0.totalOverlapSeconds < $1.totalOverlapSeconds })
        if let rel = fallback {
            let explanation = buildMeetNextExplanation(rel, myInterests: myInterests)
            #if DEBUG
            print("[MeetNext] Selected: \(rel.name) (source: fallback-any, overlap: \(rel.totalOverlapSeconds)s)")
            #endif
            return MeetNextCandidate(
                profileId: rel.profileId,
                name: rel.name,
                avatarUrl: rel.avatarUrl,
                explanation: explanation
            )
        }

        #if DEBUG
        print("[MeetNext] No candidate found — this should not happen if eligible is non-empty")
        #endif
        return nil
    }

    /// Scores and picks the best candidate from a tier.
    private func bestFromTier(
        _ candidates: [RelationshipMemory],
        tierLabel: String,
        myInterests: Set<String>,
        mySkills: Set<String>
    ) -> MeetNextCandidate? {
        struct Scored {
            let rel: RelationshipMemory
            let score: Double
            let explanation: String
            let source: String
        }

        var scored: [Scored] = []

        for rel in candidates {
            var score: Double = 0
            var explanationParts: [String] = []

            // Shared interests
            let theirInterests = Set(rel.sharedInterests.map { $0.lowercased() })
            let shared = myInterests.intersection(theirInterests)
            if !shared.isEmpty {
                score += Double(shared.count) * 2.0
                let topics = shared.prefix(2).joined(separator: " and ")
                explanationParts.append("Shared interests in \(topics)")
            }

            // Event context relevance
            if !rel.eventContexts.isEmpty {
                score += 3.0
            }

            // Connection status scoring
            if rel.connectionStatus == .none {
                score += 2.0  // Discovery value
            } else if rel.connectionStatus == .pending {
                score += 1.0
            } else if rel.connectionStatus == .accepted {
                // Connected — score by interaction depth (worth deepening)
                if rel.totalOverlapSeconds >= 300 {
                    score += 2.0
                    if explanationParts.isEmpty {
                        let mins = rel.totalOverlapSeconds / 60
                        explanationParts.append("You spent \(mins) minutes together — worth deepening")
                    }
                } else if rel.totalOverlapSeconds > 0 {
                    score += 1.0
                    if explanationParts.isEmpty {
                        explanationParts.append("A connection worth building on")
                    }
                }
            }

            // Encounter count bonus
            if rel.encounterCount >= 2 {
                score += 1.0
            } else if rel.encounterCount <= 1 {
                score += 0.5  // Fresh opportunity
            }

            // Build explanation
            let explanation: String
            if let first = explanationParts.first {
                explanation = first
            } else {
                explanation = buildMeetNextExplanation(rel, myInterests: myInterests)
            }

            // Determine source label
            let source: String
            if rel.connectionStatus == .accepted && rel.totalOverlapSeconds >= 300 {
                source = "fallback-strong-connection"
            } else if rel.connectionStatus == .accepted {
                source = "fallback-weak-connection"
            } else {
                source = tierLabel
            }

            scored.append(Scored(rel: rel, score: score, explanation: explanation, source: source))
        }

        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }

        #if DEBUG
        print("[MeetNext] Selected: \(best.rel.name) (source: \(best.source), score: \(best.score))")
        #endif

        return MeetNextCandidate(
            profileId: best.rel.profileId,
            name: best.rel.name,
            avatarUrl: best.rel.avatarUrl,
            explanation: best.explanation
        )
    }

    /// Builds a contextual explanation line for a Meet Next candidate.
    private func buildMeetNextExplanation(_ rel: RelationshipMemory, myInterests: Set<String>) -> String {
        let theirInterests = Set(rel.sharedInterests.map { $0.lowercased() })
        let shared = myInterests.intersection(theirInterests)

        if !shared.isEmpty {
            let topics = shared.prefix(2).joined(separator: " and ")
            return "Shared interests in \(topics)"
        }
        if !rel.eventContexts.isEmpty, let event = rel.eventContexts.first {
            return "You seem aligned from \(event)"
        }
        if rel.totalOverlapSeconds >= 300 {
            let mins = rel.totalOverlapSeconds / 60
            return "You spent \(mins) minutes together — worth deepening"
        }
        if rel.encounterCount >= 2 {
            return "You've crossed paths \(rel.encounterCount) times"
        }
        if rel.connectionStatus == .accepted {
            return "A connection worth building on"
        }
        return "Worth connecting with"
    }

    private func isRecentEnough(_ r: RelationshipMemory, within window: TimeInterval) -> Bool {
        let lastDate = [r.lastEncounterAt, r.lastMessageAt, r.connectionDate].compactMap { $0 }.max()
        guard let d = lastDate else { return false }
        return Date().timeIntervalSince(d) < window
    }

    private func continuePersonPrimaryLine(_ r: RelationshipMemory) -> String {
        let minutes = r.totalOverlapSeconds / 60
        if minutes >= 1 {
            return "You talked for \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        if r.encounterCount >= 2 {
            return "You crossed paths \(r.encounterCount) times"
        }
        if r.encounterCount >= 1 {
            return "You spent time together at this event"
        }
        if r.connectionStatus == .accepted {
            return "You spent time together at this event"
        }
        return "You met recently"
    }

    private func continuePersonSecondaryLine(_ r: RelationshipMemory) -> String {
        if r.needsFollowUp {
            if r.hasConversation {
                return "You haven't talked recently"
            }
            return "No follow-up yet"
        }
        if let event = r.eventContexts.first {
            if r.connectionStatus != .accepted {
                return "You met at \(event)"
            }
            return "From \(event)"
        }
        return ""
    }

    private func continueWithPersonCard(_ person: RelationshipMemory) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                SurfaceThumbnailView(
                    avatarUrl: person.avatarUrl,
                    name: person.name,
                    accentColor: .orange
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name.components(separatedBy: " ").first ?? person.name)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text(continuePersonPrimaryLine(person))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))

                    let secondary = continuePersonSecondaryLine(person)
                    if !secondary.isEmpty {
                        Text(secondary)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                FeedActionButton(
                    title: "Message",
                    icon: "bubble.left",
                    color: .orange,
                    action: { handleMessage(profileId: person.profileId) }
                )

                FeedActionButton(
                    title: "View Profile",
                    icon: "person",
                    color: .white.opacity(0.7),
                    action: { handleViewProfile(profileId: person.profileId) }
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    /// Subtle status when joining or reconnecting.
    private var joiningStatusBlock: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            ProgressView().tint(.white).scaleEffect(1.1)
            if let eventName = eventJoin.currentEventName {
                Text("Connecting to \(eventName)…")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            } else {
                Text("Connecting…")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            Spacer().frame(height: 60)
        }
    }

    /// Full briefing when joined — event framing + for you + best move.
    /// When a featured arrival person exists, the hero becomes person-led:
    /// avatar replaces the generic icon, and actions are embedded directly.
    private func joinedBriefingBlock(featured: HomeSurfaceItem?) -> some View {
        VStack(spacing: 0) {
            // A. Event Framing — person-led when featured arrival exists
            if let featured = featured {
                personHeroBlock(featured)
            } else {
                genericHeroBlock
            }

            // B. For You
            let forYou = homeState.forYouLines
            if !forYou.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FOR YOU")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.cyan.opacity(0.7))
                        .tracking(1.0)

                    ForEach(forYou, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.caption2)
                                .foregroundColor(.cyan.opacity(0.5))
                                .padding(.top, 2)
                            Text(line)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            // C. Best Move
            let bestMove = homeState.bestMoveLines
            if !bestMove.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BEST MOVE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange.opacity(0.7))
                        .tracking(1.0)

                    ForEach(bestMove, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange.opacity(0.5))
                                .padding(.top, 2)
                            Text(line)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }

    /// Person-led hero: avatar at top, headline, support line, then actions.
    /// Replaces the generic icon when a featured arrival is surfaced.
    /// When inside the event (anchor confirmed), language is more decisive.
    private func personHeroBlock(_ item: HomeSurfaceItem) -> some View {
        let isInside = UserPresenceStateResolver.current == .insideEvent
        let heroHeadline = isInside
            ? homeState.briefingHeadline
            : homeState.briefingHeadline

        return VStack(spacing: 10) {
            HeroAvatarView(
                avatarUrl: item.avatarUrl,
                name: item.name,
                accentColor: briefingAccentColor
            )

            Text(heroHeadline)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Text(homeState.briefingBody)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Actions embedded in the hero — zone-aware label
            HStack(spacing: 12) {
                FeedActionButton(
                    title: isInside ? UserPresenceStateResolver.shortMeetLabel : item.actionLabel,
                    icon: item.actionLabel == "Go say hi" || isInside ? "hand.wave" : "location",
                    color: .orange,
                    action: { handleAction(item) }
                )

                if item.profileId != nil {
                    FeedActionButton(
                        title: "View Profile",
                        icon: "person",
                        color: .white.opacity(0.7),
                        action: { handleAction(item, override: .viewProfile) }
                    )
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    /// Generic hero block — used when no featured arrival person exists.
    private var genericHeroBlock: some View {
        VStack(spacing: 10) {
            Image(systemName: homeState.briefingIcon)
                .font(.system(size: 28))
                .foregroundColor(briefingAccentColor)

            Text(homeState.briefingHeadline)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text(homeState.briefingBody)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var briefingAccentColor: Color {
        switch homePresentation {
        case .liveEvent:
            // Graduated by feed richness
            return surface.isEmpty ? .cyan.opacity(0.7) : .orange
        case .eventContinuation:
            return .orange
        case .personContinuation:
            return .orange
        case .joining:
            return .gray.opacity(0.5)
        case .onboarding:
            return .gray.opacity(0.5)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading…").font(.subheadline).foregroundColor(.gray)
        }
    }

    /// Identity screen shown for 0.8–1.5s while state resolves.
    /// The user sees the brand logo and a purposeful message — not a blank spinner.
    private var launchResolvingState: some View {
        VStack(spacing: 16) {
            Spacer()
            if UIImage(named: "NearifyLogo") != nil {
                Image("NearifyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityLabel("Nearify")
            } else {
                Text("nearify.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("nearify.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text("Finding people around you...")
                .font(.system(size: 16))
                .foregroundColor(.gray)
            Spacer()
        }
    }

    // MARK: - Action Handlers (Action-Aware)

    private func handleAction(_ item: HomeSurfaceItem, override: SurfaceActionType? = nil) {
        let action = override ?? item.actionType

        // Record action in memory FIRST — surface reacts immediately
        surface.recordAction(item: HomeSurfaceItem(
            section: item.section, profileId: item.profileId, name: item.name,
            headline: item.headline, actionType: action,
            temporalState: item.temporalState, priority: item.priority,
            eventId: item.eventId
        ))

        switch action {
        case .findAttendee:
            if let profileId = item.profileId {
                handleFindAttendee(profileId: profileId)
            }
        case .reply, .followUp, .message:
            if let profileId = item.profileId {
                handleMessage(profileId: profileId)
            }
        case .connect:
            if let profileId = item.profileId {
                handleConnect(profileId: profileId)
            }
        case .jumpBack:
            switchTab(to: .event)
        case .viewProfile:
            if let profileId = item.profileId {
                handleViewProfile(profileId: profileId)
            }
        }
    }

    private func handleViewProfile(profileId: UUID) {
        navigationPath.append(FeedRoute.profileDetail(profileId: profileId))
    }

    private func switchTab(to target: AppTab, source: TabChangeSource = .user) {
        if source == .user, target == .event {
            eventJoin.setIntent(.navigateToEvent)
        }
        _ = NavigationState.shared.requestTabChange(
            from: selectedTab,
            to: target,
            source: source,
            binding: &selectedTab
        )
    }

    // MARK: - People CTA Routing
    //
    // Routes the "See who's here" / "Go say hi" action based on attendee count.
    // Zero attendees → solo-state sheet.
    // One attendee → direct to that person.
    // Multiple → find the specific person or show ranked list.

    private func handlePeopleCTA(specificPersonId: UUID?) {
        let crowdState = EventCrowdStateResolver.current

        #if DEBUG
        print("[PeopleCTA] crowdState=\(crowdState.rawValue) specificPerson=\(specificPersonId?.uuidString.prefix(8) ?? "nil")")
        #endif

        if crowdState == .empty {
            #if DEBUG
            print("[PeopleCTA] empty → presenting solo state")
            #endif
            showSoloState = true
            return
        }

        if let personId = specificPersonId {
            handleFindAttendee(profileId: personId)
            return
        }

        if crowdState == .single {
            let others = attendeesService.attendees.filter {
                $0.id != AuthService.shared.currentUser?.id && $0.isHereNow
            }
            if let only = others.first {
                #if DEBUG
                print("[PeopleCTA] single → direct to \(only.name)")
                #endif
                handleFindAttendee(profileId: only.id)
                return
            }
        }

        // pair or group, no specific target → Event tab
        #if DEBUG
        print("[PeopleCTA] \(crowdState.rawValue) → switching to Event tab")
        #endif
        switchTab(to: .event)
    }

    private func handleFindAttendee(profileId: UUID, source: FindAttendeeSource = .explore) {
        let attendees = attendeesService.attendees
        let attendee: EventAttendee

        if let found = attendees.first(where: { $0.id == profileId }) {
            attendee = found
        } else {
            // Not in backend list — try offline fallback from cache + BLE
            let prefix = String(profileId.uuidString.prefix(8)).lowercased()
            let hasBLE = hasBLESignalForAttendee(profileId: profileId)

            if hasBLE {
                // BLE signal exists — construct minimal attendee for Find
                attendee = ProfileCache.shared.offlineAttendee(forPrefix: prefix, profileId: profileId)
                #if DEBUG
                print("[FindGate] 📡 Offline fallback: \(attendee.name) (BLE present, backend absent)")
                #endif
            } else {
                #if DEBUG
                print("[FindGate] ⛔ Blocked: profile \(profileId.uuidString.prefix(8)) not in active list and no BLE signal")
                #endif
                staleAttendeeName = ProfileCache.shared.displayName(forPrefix: prefix)
                showStaleAttendeeAlert = true
                return
            }
        }

        // Check findability: requires BLE signal OR fresh heartbeat.
        let hasBLE = hasBLESignalForAttendee(profileId: profileId)
        let findState = attendee.findability(hasBLESignal: hasBLE)

        #if DEBUG
        print("[FindGate] \(attendee.name): presence=\(attendee.presenceState.rawValue) ble=\(hasBLE) findability=\(findState.rawValue)")
        #endif

        switch findState {
        case .liveSignal, .recentlySeen:
            // Findable — proceed to Find sheet.
            presentFindAttendee(attendee: attendee, source: source)
            #if DEBUG
            print("[FindGate] ✅ Navigating to Find: \(attendee.name)")
            #endif

        case .unavailable:
            // Not findable — show message instead of navigating to stale target.
            #if DEBUG
            print("[FindGate] ⛔ Blocked stale target: \(attendee.name) (presence=\(attendee.presenceState.rawValue), ble=\(hasBLE))")
            #endif
            staleAttendeeName = attendee.name.components(separatedBy: " ").first ?? attendee.name
            showStaleAttendeeAlert = true
        }
    }

    /// Checks if BLEScannerService has a recent signal for this attendee.
    /// Matches by community ID prefix in the BLE device name (BCN-<prefix>).
    private func hasBLESignalForAttendee(profileId: UUID) -> Bool {
        let prefix = String(profileId.uuidString.prefix(8)).lowercased()
        let devices = BLEScannerService.shared.getKnownBeacons()
        let now = Date()
        return devices.contains { device in
            device.name.hasPrefix("BCN-\(prefix)")
            && now.timeIntervalSince(device.lastSeen) < 15
        }
    }

    private func presentFindAttendee(attendee: EventAttendee, source: FindAttendeeSource) {
        let mode: FindAttendeeConnectionMode
        switch source {
        case .brief:
            mode = .briefRecommendation(attendee)
        case .explore:
            mode = .explore(source: .explore)
        }
        findAttendeeDestination = FindAttendeeDestination(attendee: attendee, connectionMode: mode)
    }

    private func handleMessage(profileId: UUID) {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true

        Task {
            let connected = await ConnectionService.shared.isConnected(with: profileId)
            guard connected else {
                await MainActor.run {
                    isOpeningConversation = false
                    showNotConnectedAlert = true
                }
                return
            }

            var targetName = "..."
            if let profile = try? await ProfileService.shared.fetchProfileById(profileId) {
                targetName = profile.name
            }

            let eventId = await MainActor.run { EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) } }
            let eventName = await MainActor.run { EventJoinService.shared.currentEventName }

            do {
                let convo = try await MessagingService.shared.getOrCreateConversation(
                    with: profileId, eventId: eventId, eventName: eventName
                )
                await MessagingService.shared.fetchMessages(conversationId: convo.id)
                await MainActor.run {
                    activeConversation = ConversationDestination(
                        id: convo.id, targetProfileId: profileId,
                        targetName: targetName, conversation: convo
                    )
                    isOpeningConversation = false
                }
            } catch {
                await MainActor.run {
                    isOpeningConversation = false
                    if case MessagingError.notConnected = error { showNotConnectedAlert = true }
                }
            }
        }
    }

    private func handleConnect(profileId: UUID) {
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            _ = try? await ConnectionService.shared.createConnectionIfNeeded(to: profileId.uuidString)
            feedService.requestRefresh(reason: "connection-created")
            surface.requestRefresh(reason: "connection-created")
            await MainActor.run { isConnecting = false }
        }
    }
}
