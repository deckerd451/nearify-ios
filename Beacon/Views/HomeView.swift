import SwiftUI

struct HomeView: View {
    private struct BriefConnectionDestination: Identifiable {
        let attendee: EventAttendee
        var id: UUID { attendee.id }
    }

    @Binding var selectedTab: AppTab
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var explore = ExploreEventsService.shared
    @ObservedObject private var resolver = AttendeeStateResolver.shared
    @ObservedObject private var briefController = BriefHydrationController.shared
    @State private var showScanner = false
    @State private var showLeaveConfirmation = false
    @State private var showLastSummaryRecap = false
    @State private var showEventBrief = false
    @State private var showGoalPickerSheet = false
    @State private var selectedPreCheckInIntent: String?
    @State private var selectedPreCheckInIntentEventId: String?
    @State private var autoPresentedBriefEventId: String?
    @State private var briefConnectionDestination: BriefConnectionDestination?
    @State private var pendingBriefConnectionDestination: BriefConnectionDestination?
    @State private var showCheckInConfirmation = false
    @State private var checkInDismissTask: Task<Void, Never>?
    @State private var hasMounted = false

    var body: some View {
        ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        eventHeader
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 24)

                        if attendeesService.isLoading && attendeesService.attendees.isEmpty && eventJoin.isCheckedIn {
                            loadingState.padding(.top, 60)
                        } else if eventJoin.isEventJoined && !eventJoin.isCheckedIn {
                            EmptyView()
                        } else if !eventJoin.isCheckedIn {
                            notJoinedState
                        } else if attendeesService.attendees.isEmpty {
                            // Checked in but nobody visible yet — surface the best
                            // contextual action (brief person, follow-up, messages).
                            nextBestActionCard(minPriority: 0.35)
                            emptyState.padding(.top, 60)
                        } else {
                            // Attendee list is the primary surface; only surface
                            // unread messages (priority ≥ 0.95) so the card
                            // doesn't compete with the list itself.
                            nextBestActionCard(minPriority: 0.95)
                            attendeeList
                        }
                    }
                }
                if showCheckInConfirmation {
                    checkInConfirmationCard
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color.black.ignoresSafeArea())
            .refreshable { attendeesService.refresh() }
            .onChange(of: eventJoin.currentEventID) { _, _ in
                maybePresentEventBrief()
            }
            .onChange(of: eventJoin.isCheckedIn) { _, _ in
                maybePresentEventBrief()
            }
            .onChange(of: eventJoin.isRestoringFromPersist) { _, isRestoring in
                // When cold-launch restore completes, decide whether to show the brief.
                if !isRestoring {
                    maybePresentEventBrief()
                }
            }
            .onChange(of: eventJoin.isCheckedIn) { oldValue, newValue in
                guard !oldValue, newValue else { return }
                presentCheckInConfirmation()
                #if DEBUG
                EventParticipationStateResolver.logAudit(renderingSurface: "HomeView.checkedIn")
                #endif
            }
            .onAppear {
                guard !hasMounted else { return }
                hasMounted = true
                #if DEBUG
                EventParticipationStateResolver.logAudit(renderingSurface: "HomeView.onAppear")
                #endif
                DispatchQueue.main.async {
                    maybePresentEventBrief()
                }
            }
            .onDisappear {
                checkInDismissTask?.cancel()
            }
            .confirmationDialog("Say Goodbye?", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave Event", role: .destructive) { Task { await eventJoin.leaveEvent() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(leaveEventMessage)
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(
                    selectedTab: $selectedTab,
                    onSuccess: { _ in
                        showScanner = false
                        // EventJoinService publishes state changes;
                        // HomeView observes them automatically.
                    },
                    onCancel: {
                        showScanner = false
                    }
                )
            }
            .sheet(isPresented: $showLastSummaryRecap) {
                if let summary = eventJoin.postEventSummary {
                    LastSummaryRecapView(summary: summary)
                }
            }
            .sheet(isPresented: $showEventBrief, onDismiss: {
                if let pending = pendingBriefConnectionDestination {
                    briefConnectionDestination = pending
                    pendingBriefConnectionDestination = nil
                }
            }) {
                eventBriefSheet
            }
            .sheet(isPresented: $showGoalPickerSheet) {
                goalPickerSheet
            }
            .fullScreenCover(item: $briefConnectionDestination) { destination in
                FindAttendeeView(
                    attendee: destination.attendee,
                    connectionMode: .briefRecommendation(destination.attendee)
                )
            }
    }

    private var leaveEventMessage: String {
        let names = unsavedInteractionNames
        guard !names.isEmpty else {
            return "This checks you out and prepares your post-event summary."
        }

        let namesText: String
        if names.count == 1 {
            namesText = names[0]
        } else if names.count == 2 {
            namesText = "\(names[0]) and \(names[1])"
        } else {
            namesText = "\(names[0]), \(names[1]), and \(names.count - 2) others"
        }

        return "You spent time with \(namesText) — save any connections?"
    }

    private var unsavedInteractionNames: [String] {
        guard let eventId = eventJoin.currentEventID,
              let eventUUID = UUID(uuidString: eventId) else {
            return []
        }

        let attendeeNamesById = Dictionary(uniqueKeysWithValues: attendeesService.attendees.map { ($0.id, IdentityDisplayName.primaryName(name: $0.name)) })

        let profileIds = LocalEncounterStore.shared.encounters(forEvent: eventUUID)
            .filter { $0.duration >= 30 }
            .compactMap(\.resolvedProfileId)
            .filter { !resolver.connectedIds.contains($0) }
            .filter { !ConnectionPromptStateStore.shared.isSaved(profileId: $0, eventId: eventId) }

        var seen = Set<UUID>()
        let orderedUnique = profileIds.filter { seen.insert($0).inserted }
        return orderedUnique.compactMap { attendeeNamesById[$0] }.prefix(3).map { $0 }
    }

    // MARK: - Event Header

    private var eventDisplayName: String {
        eventJoin.currentEventName ?? presence.currentEvent ?? "Event"
    }

    private var eventHeader: some View {
        let state = EventParticipationStateResolver.resolve()
        return VStack(spacing: 12) {
            switch state {
            case .checkedIn:
                joinedCard
            case .joinedTodayNotCheckedIn, .nearVenueNotCheckedIn, .joinedUpcoming:
                preCheckInCard
            case .restoring:
                restoringCard
            case .left, .none:
                // Only show the legacy presence card when there is an active EventPresence
                // session AND no explicit join state — this covers the rare edge case of a
                // stale heartbeat surviving a force-quit. If there's no presence context either,
                // fall through to the standard scan card.
                if presence.currentEvent != nil && !eventJoin.isEventJoined {
                    legacyCard
                } else {
                    scanCard
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: eventJoin.isCheckedIn)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: eventJoin.isEventJoined)
    }

    private var restoringCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(VisualStyle.primaryAction)
            Text("Restoring your event…")
                .font(.subheadline)
                .foregroundColor(VisualStyle.secondaryText)
            Spacer()
        }
        .padding()
        .elevatedCard(accent: VisualStyle.primaryAction, glow: 0.1)
    }

    // MARK: - Scan Card (State A)

    private var scanCard: some View {
        Button(action: { showScanner = true }) {
            VStack(spacing: 14) {
                Text("READY TO JOIN")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundColor(VisualStyle.tertiaryText)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(VisualStyle.primaryAction)

                VStack(spacing: 4) {
                    Text("Join an Event")
                        .font(.title3.weight(.semibold))
                        .fontWeight(.semibold)
                    Text("Scan event QR to get started")
                        .font(.subheadline)
                        .foregroundColor(VisualStyle.secondaryText)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .elevatedCard(accent: VisualStyle.primaryAction, glow: 0.2)
        }
        .buttonStyle(PressableScaleButtonStyle())
    }

    // MARK: - Joined Card (State B)

    private var joinedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                PresencePulseDot(color: VisualStyle.live)
                Text("You’re here")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundColor(VisualStyle.live.opacity(0.9))
                Spacer()
                let liveCount = attendeesService.liveOtherCount
                if liveCount > 0 {
                    Text(liveCount == 1 ? "1 person nearby" : "\(liveCount) people nearby")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(VisualStyle.tertiaryText)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .foregroundColor(VisualStyle.live)
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(eventDisplayName)
                        .font(.headline.weight(.semibold))
                    Text(nearbyCountLine)
                        .font(.caption)
                        .foregroundColor(VisualStyle.secondaryText)
                }

                Spacer()
            }

            Button {
                showEventBrief = true
            } label: {
                Text(briefCTALabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(VisualStyle.intelligence.opacity(0.28)))
            }
            .buttonStyle(PressableScaleButtonStyle())
        }
        .padding()
        .elevatedCard(accent: VisualStyle.live, glow: 0.25)
        .overlay(
            RoundedRectangle(cornerRadius: VisualStyle.cardCornerRadius, style: .continuous)
                .stroke(LinearGradient(colors: [VisualStyle.live.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
        )
        .overlay(alignment: .bottomTrailing) {
            Button {
                showLeaveConfirmation = true
            } label: {
                Text("Say Goodbye")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(VisualStyle.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(VisualStyle.danger.opacity(0.18)))
            }
            .buttonStyle(PressableScaleButtonStyle())
            .padding(.trailing, 10)
            .padding(.bottom, 8)
        }
    }

    private var nearbyCountLine: String {
        let count = attendeesService.liveOtherCount
        return count == 1 ? "1 person nearby" : "\(count) people nearby"
    }

    private var briefCTALabel: String {
        guard let brief = briefController.currentBrief,
              let topPerson = brief.priorityPeople.first else {
            return "See suggestions"
        }
        let name = IdentityDisplayName.primaryName(name: topPerson.name)
        return "Meet \(name)"
    }

    private var preCheckInCard: some View {
        let attendeeCount = activeEventExploreModel?.activeAttendeeCount ?? 0
        let relativeTime = activeEventTimeLine
        let currentEventId = eventJoin.currentEventID
        let localIntent = (selectedPreCheckInIntentEventId == currentEventId) ? selectedPreCheckInIntent : nil
        let cachedIntent = (EventContextService.shared.cachedContext?.intentPrimary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? EventContextService.shared.cachedContext?.intentPrimary
            : nil
        let resolvedIntent = localIntent ?? cachedIntent
        let hasIntent = resolvedIntent?.isEmpty == false

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("You're going")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundColor(VisualStyle.primaryAction.opacity(0.9))
                Spacer()
                if attendeeCount > 0 {
                    Text("\(attendeeCount) going")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(VisualStyle.tertiaryText)
                }
            }

            Text(eventDisplayName)
                .font(.headline.weight(.semibold))

            HStack(spacing: 8) {
                Label(relativeTime, systemImage: "calendar")
            }
            .font(.caption)
            .foregroundColor(VisualStyle.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if hasIntent {
                        Text(resolvedIntent ?? "")
                            .font(.caption)
                            .foregroundColor(VisualStyle.secondaryText)
                            .lineLimit(1)
                    } else {
                        Text("What do you want from tonight?")
                            .font(.caption)
                            .foregroundColor(VisualStyle.tertiaryText)
                            .lineLimit(1)
                    }

                    Button {
                        print("[GoalPicker] opened")
                        showGoalPickerSheet = true
                    } label: {
                        Text(hasIntent ? "Change" : "Set goal")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(VisualStyle.intelligence)
                    }
                    .buttonStyle(PressableScaleButtonStyle())
                }
            }

            Button {
                EventPresenceService.shared.setActivationIntent(.userCheckIn)
                Task { await eventJoin.checkIn() }
            } label: {
                Text("Check In")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(VisualStyle.primaryAction))
            }
            .buttonStyle(PressableScaleButtonStyle())

            Text("People nearby only become visible after you check in.")
                .font(.caption2)
                .foregroundColor(VisualStyle.tertiaryText)

            preEventIntelligenceInlineRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .elevatedCard(accent: VisualStyle.primaryAction, glow: 0.2)
    }

    // MARK: - Legacy Card

    private var legacyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(VisualStyle.live)
                .font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(eventDisplayName)
                    .font(.headline.weight(.semibold))
                Text("Event detected")
                    .font(.caption)
                    .foregroundColor(VisualStyle.secondaryText)
            }
            Spacer()
        }
        .padding()
        .elevatedCard(accent: VisualStyle.live, glow: 0.2)
    }

    // MARK: - Attendee List

    private var attendeeList: some View {
        LazyVStack(spacing: 8) {
            HStack {
                Text("People nearby")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(VisualStyle.secondaryText)
                Spacer()
                Text("\(attendeesService.attendeeCount)")
                    .font(.caption)
                    .foregroundColor(VisualStyle.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            ForEach(attendeesService.attendees) { attendee in
                NavigationLink(value: attendee.id) {
                    AttendeeCardView(attendee: attendee)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 24)
        .navigationDestination(for: UUID.self) { attendeeId in
            if let attendee = attendeesService.attendees.first(where: { $0.id == attendeeId }) {
                PersonDetailView(attendee: attendee)
            }
        }
    }

    // MARK: - Empty / Loading / Neutral

    /// Compact inline row replacing the old full intelligence card.
    /// One tappable line that opens the brief sheet — minimal visual weight.
    private var preEventIntelligenceInlineRow: some View {
        let brief = activePreEventBrief
        let count = brief?.priorityPeople.count ?? 0
        let label: String = {
            if count >= 2 { return "\(count) people may be worth meeting" }
            if count == 1 { return "1 person may be worth meeting" }
            return "See who may be there"
        }()

        return Button {
            showEventBrief = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundColor(VisualStyle.intelligence.opacity(0.7))
                Text(label)
                    .font(.caption)
                    .foregroundColor(VisualStyle.intelligence.opacity(0.85))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(VisualStyle.tertiaryText)
            }
        }
        .buttonStyle(PressableScaleButtonStyle())
    }

    // MARK: - Next Best Action

    /// Returns the NBA card configured with HomeView's navigation callbacks.
    /// `minPriority` lets callers suppress lower-priority actions when the
    /// surrounding UI already covers them (e.g. attendee list is the surface).
    private func nextBestActionCard(minPriority: Double) -> some View {
        NextBestActionCard(minPriority: minPriority) { action in
            switch action {
            case .openMessages:
                switchTab(to: .messages)
            case .findAttendee(let attendee):
                briefConnectionDestination = BriefConnectionDestination(attendee: attendee)
            case .showBrief:
                showEventBrief = true
            case .showGoalPicker:
                showGoalPickerSheet = true
            case .goToPeople:
                switchTab(to: .people)
            }
        }
    }

    private var activeEventExploreModel: ExploreEvent? {
        guard let eventIdString = eventJoin.currentEventID,
              let eventId = UUID(uuidString: eventIdString) else { return nil }
        let allEvents = [explore.currentEvent] + explore.happeningNow + explore.upcoming + explore.recent
        return allEvents.compactMap { $0 }.first(where: { $0.id == eventId })
    }

    private var activeEventTimeLine: String {
        guard let event = activeEventExploreModel else { return "Time pending" }
        return event.dateDisplay ?? "Time pending"
    }

    private var activePreEventBrief: PreEventBriefBuilder.Brief? {
        briefController.currentBrief
    }

    private var notJoinedState: some View {
        VStack(spacing: 12) {
            Text("Find your next event")
                .font(.headline)
                .foregroundColor(VisualStyle.secondaryText)
            Text("Join an event and Nearify will quietly help you meet the right people.")
                .font(.subheadline)
                .foregroundColor(VisualStyle.tertiaryText)
                .multilineTextAlignment(.center)
            Button {
                switchTab(to: .event)
            } label: {
                Text("Browse Events")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(VisualStyle.primaryAction))
            }
            .buttonStyle(PressableScaleButtonStyle())

            if let summary = eventJoin.postEventSummary {
                Button {
                    showLastSummaryRecap = true
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Last Summary")
                                .font(.caption)
                                .foregroundColor(VisualStyle.intelligence)
                            Spacer()
                            Text("View recap")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.75))
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.75))
                        }

                        Text(summary.eventName)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(summary.totalPeopleMet > 0
                             ? "\(summary.totalPeopleMet) \(summary.totalPeopleMet == 1 ? "interaction" : "interactions") captured"
                             : "No confirmed interactions captured")
                            .font(.caption2)
                            .foregroundColor(.gray)

                        if !summary.narrativeWrapUp.isEmpty {
                            Text(summary.narrativeWrapUp)
                                .font(.caption2)
                                .foregroundColor(.gray.opacity(0.9))
                                .lineLimit(2)
                        } else {
                            Text(summary.snapshot.activityLine)
                                .font(.caption2)
                                .foregroundColor(.gray.opacity(0.9))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .elevatedCard(accent: VisualStyle.intelligence, glow: 0.12)
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
        .padding(.top, 56)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(VisualStyle.tertiaryText)
            Text("Looking for people")
                .font(.headline)
                .foregroundColor(VisualStyle.secondaryText)
            Text("Walk around — Nearify will surface the right people as they arrive.")
                .font(.subheadline)
                .foregroundColor(VisualStyle.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .multilineTextAlignment(.center)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking for people nearby…")
                .font(.subheadline)
                .foregroundColor(VisualStyle.secondaryText)
        }
    }

    private func switchTab(to target: AppTab, source: TabChangeSource = .user) {
        if source == .user, target == .event {
            eventJoin.setIntent(.navigateToEvent)
        }
        _ = NavigationState.shared.requestTabChange(
            from: selectedTab,
            to: target,
            source: source,
            sourceName: "HomeView.switchTab",
            binding: &selectedTab
        )
    }

    @ViewBuilder
    private var eventBriefSheet: some View {
        NavigationStack {
            if let brief = resolvedBriefForSheet {
                ScrollView {
                    PreEventBriefView(
                        brief: brief,
                        hydrationState: briefController.hydrationState
                    ) { recommendation in
                        showEventBrief = false
                        pendingBriefConnectionDestination = destinationForBriefRecommendation(recommendation)
                    }
                    .padding()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Dismiss") {
                            showEventBrief = false
                        }
                    }
                }
            } else {
                Text("Suggestions will appear as more people join.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var goalPickerSheet: some View {
        NavigationStack {
            List {
                Section("Pick what fits tonight") {
                    ForEach(EventContextService.supportedIntents, id: \.self) { intent in
                        Button(intent) {
                            handleGoalSelection(intent)
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Tonight's goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { showGoalPickerSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func handleGoalSelection(_ intent: String) {
        print("[GoalPicker] selected intent=\(intent)")
        selectedPreCheckInIntent = intent
        selectedPreCheckInIntentEventId = eventJoin.currentEventID
        showGoalPickerSheet = false

        guard let rawEventId = eventJoin.currentEventID,
              let eventId = UUID(uuidString: rawEventId) else { return }
        Task {
            await EventContextService.shared.updateIntentPrimary(eventId: eventId, intent: intent)
        }
    }

    private func maybePresentEventBrief() {
        guard hasMounted else { return }
        // Do not auto-present during cold-launch restore — wait for backend confirmation
        // so the brief doesn't flash and disappear if membership was revoked.
        guard !eventJoin.isRestoringFromPersist else { return }
        guard eventJoin.isEventJoined,
              !eventJoin.isCheckedIn,
              let eventId = eventJoin.currentEventID else {
            return
        }
        guard autoPresentedBriefEventId != eventId else { return }
        autoPresentedBriefEventId = eventId
        showEventBrief = true
        #if DEBUG
        EventParticipationStateResolver.logAudit(renderingSurface: "HomeView.briefPresented")
        #endif
    }

    private var resolvedBriefForSheet: PreEventBriefBuilder.Brief? {
        // Prefer the live hydrated brief; fall back to an inline build if hydration
        // hasn't started yet (e.g. user taps "Briefing" before join flow completes).
        if let live = briefController.currentBrief { return live }
        guard let eventIdString = eventJoin.currentEventID,
              let eventId = UUID(uuidString: eventIdString) else { return nil }
        return PreEventBriefBuilder.build(eventId: eventId, eventName: eventDisplayName)
    }

    private func destinationForBriefRecommendation(
        _ recommendation: PreEventBriefBuilder.PriorityPerson?
    ) -> BriefConnectionDestination? {
        guard let recommendation else { return nil }

        let resolvedAttendee = attendeesService.attendees.first(where: { $0.id == recommendation.id })
            ?? EventAttendee(
                id: recommendation.id,
                name: recommendation.name,
                avatarUrl: recommendation.avatarUrl,
                bio: recommendation.reason,
                skills: nil,
                interests: nil,
                energy: recommendation.matchScore ?? 0.5,
                lastSeen: Date()
            )
        #if DEBUG
        print("[Brief] launching find flow for \(recommendation.name)")
        #endif
        return BriefConnectionDestination(attendee: resolvedAttendee)
    }

    private var checkInConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You’re in.")
                .font(.headline)
                .foregroundColor(.white)
            Text("People nearby will appear automatically.")
                .font(.subheadline)
                .foregroundColor(VisualStyle.secondaryText)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCheckInConfirmation = false
                }
                switchTab(to: .people, source: .user)
            } label: {
                Text("Who’s here")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(VisualStyle.primaryAction))
            }
            .buttonStyle(PressableScaleButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .elevatedCard(accent: VisualStyle.live, glow: 0.25)
    }

    private func presentCheckInConfirmation() {
        checkInDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            showCheckInConfirmation = true
        }

        checkInDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showCheckInConfirmation = false
                }
            }
        }
    }
}

private struct LastSummaryRecapView: View {
    let summary: PostEventSummary
    @Environment(\.dismiss) private var dismiss
    @State private var activeConversation: RecapConversationTarget?
    @State private var profileSheetTarget: RecapProfileSheetTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    PostEventSummaryView(
                        summary: summary,
                        onMessage: { profileId in
                            openConversation(profileId: profileId)
                        },
                        onViewProfile: { profileId in
                            profileSheetTarget = RecapProfileSheetTarget(profileId: profileId)
                        }
                    )
                    .padding()
                }
            }
            .navigationTitle("Event Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $profileSheetTarget) { target in
            NavigationStack { FeedProfileDetailView(profileId: target.profileId) }
        }
        .sheet(item: $activeConversation) { target in
            ConversationView(
                targetProfileId: target.profileId,
                preloadedConversation: target.conversation,
                preloadedName: target.name
            )
        }
    }

    private func openConversation(profileId: UUID) {
        Task {
            let convo = try? await MessagingService.shared.getOrCreateConversation(with: profileId)
            guard let convo else { return }
            await MessagingService.shared.fetchMessages(conversationId: convo.id)

            var targetName = "Connection"
            if let profile = try? await ProfileService.shared.fetchProfileById(profileId) {
                targetName = profile.name
            }

            await MainActor.run {
                activeConversation = RecapConversationTarget(
                    profileId: profileId,
                    name: targetName,
                    conversation: convo
                )
            }
        }
    }
}

private struct RecapProfileSheetTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
}

private struct RecapConversationTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let conversation: Conversation
}

#Preview {
    HomeView(selectedTab: .constant(.home))
}
