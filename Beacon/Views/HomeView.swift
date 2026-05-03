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
    @ObservedObject private var resolver = AttendeeStateResolver.shared
    @State private var showScanner = false
    @State private var showLeaveConfirmation = false
    @State private var showLastSummaryRecap = false
    @State private var showEventBrief = false
    @State private var autoPresentedBriefEventId: String?
    @State private var briefConnectionDestination: BriefConnectionDestination?
    @State private var showCheckInConfirmation = false
    @State private var checkInDismissTask: Task<Void, Never>?
    @State private var hasMounted = false

    var body: some View {
        NavigationStack {
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
                            joinedNotCheckedInState
                        } else if !eventJoin.isCheckedIn {
                            notJoinedState
                        } else if attendeesService.attendees.isEmpty {
                            emptyState.padding(.top, 60)
                        } else {
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
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { attendeesService.refresh() }
            .onChange(of: eventJoin.currentEventID) { _, _ in
                maybePresentEventBrief()
            }
            .onChange(of: eventJoin.isCheckedIn) { _, _ in
                maybePresentEventBrief()
            }
            .onChange(of: eventJoin.isCheckedIn) { oldValue, newValue in
                guard !oldValue, newValue else { return }
                presentCheckInConfirmation()
            }
            .onAppear {
                guard !hasMounted else { return }
                hasMounted = true
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
            .sheet(isPresented: $showEventBrief) {
                eventBriefSheet
            }
            .fullScreenCover(item: $briefConnectionDestination) { destination in
                FindAttendeeView(
                    attendee: destination.attendee,
                    connectionMode: .briefRecommendation(destination.attendee)
                )
            }
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

        let attendeeNamesById = Dictionary(uniqueKeysWithValues: attendeesService.attendees.map { ($0.id, $0.name) })

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
        VStack(spacing: 12) {
            if eventJoin.isCheckedIn {
                joinedCard
            } else if eventJoin.isEventJoined {
                preCheckInCard
            } else if presence.currentEvent != nil {
                legacyCard
            } else {
                scanCard
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: eventJoin.isCheckedIn)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: eventJoin.isEventJoined)
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
            Text("LIVE • \(max(attendeesService.attendeeCount, 1)) NEARBY")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundColor(VisualStyle.tertiaryText)

            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .foregroundColor(VisualStyle.live)
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("You’re at \(eventDisplayName)")
                        .font(.headline.weight(.semibold))
                    Text(nearbyCountLine)
                        .font(.caption)
                        .foregroundColor(VisualStyle.secondaryText)
                }

                Spacer()
                PresencePulseDot(color: VisualStyle.live)

                if attendeesService.attendeeCount > 0 {
                    Text("\(attendeesService.attendeeCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(VisualStyle.live.opacity(0.22)))
                }
            }

            Button {
                showEventBrief = true
            } label: {
                Text("Who to Talk To")
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
        let count = attendeesService.attendeeCount
        return count == 1 ? "1 person nearby" : "\(count) people nearby"
    }

    private var preCheckInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("JOINED • NOT LIVE")
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundColor(VisualStyle.tertiaryText)
            Text(eventDisplayName)
                .font(.headline.weight(.semibold))
            Text("Check in to go live")
                .font(.caption)
                .foregroundColor(VisualStyle.secondaryText)

            Button {
                EventPresenceService.shared.setActivationIntent(.userCheckIn)
                Task { await eventJoin.checkIn() }
            } label: {
                Text("Check In")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(VisualStyle.primaryAction))
            }
            .buttonStyle(PressableScaleButtonStyle())

            Button {
                showEventBrief = true
            } label: {
                Text("Prepare for Event")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(VisualStyle.intelligence.opacity(0.28)))
            }
            .buttonStyle(PressableScaleButtonStyle())
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
                Text("Checked-In Attendees")
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

    private var joinedNotCheckedInState: some View {
        VStack(spacing: 12) {
            Text("You’ve joined. Check in when you arrive to start meeting people.")
                .font(.headline)
                .foregroundColor(VisualStyle.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 56)
        .padding(.horizontal, 24)
    }

    private var notJoinedState: some View {
        VStack(spacing: 12) {
            Text("No live event yet")
                .font(.headline)
                .foregroundColor(VisualStyle.secondaryText)
            Text("Explore events, join one, then check in when you arrive.")
                .font(.subheadline)
                .foregroundColor(VisualStyle.tertiaryText)
                .multilineTextAlignment(.center)
            Button {
                switchTab(to: .event)
            } label: {
                Text("Go to Explore")
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

                        Text("\(summary.totalPeopleMet) people met")
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
            Image(systemName: "person.3")
                .font(.system(size: 40))
                .foregroundColor(VisualStyle.tertiaryText)
            Text("You’re checked in. We’ll show people here as they appear.")
                .font(.headline)
                .foregroundColor(VisualStyle.secondaryText)
        }
        .multilineTextAlignment(.center)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading attendees…")
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
            binding: &selectedTab
        )
    }

    @ViewBuilder
    private var eventBriefSheet: some View {
        NavigationStack {
            if let eventIdString = eventJoin.currentEventID,
               let eventId = UUID(uuidString: eventIdString) {
                let brief = PreEventBriefBuilder.build(
                    eventId: eventId,
                    eventName: eventDisplayName
                )
                ScrollView {
                    PreEventBriefView(
                        brief: brief,
                        ctaTitle: "Continue"
                    ) { recommendation in
                        showEventBrief = false
                        guard let recommendation else {
                            switchTab(to: .home, source: .user)
                            return
                        }

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

                        briefConnectionDestination = BriefConnectionDestination(attendee: resolvedAttendee)
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
                Text("No event brief available.")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func maybePresentEventBrief() {
        guard hasMounted else { return }
        guard eventJoin.isEventJoined,
              !eventJoin.isCheckedIn,
              let eventId = eventJoin.currentEventID else {
            return
        }
        guard autoPresentedBriefEventId != eventId else { return }
        autoPresentedBriefEventId = eventId
        showEventBrief = true
    }

    private var checkInConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You’re checked in.\nNearify is now capturing who you meet.")
                .font(.headline)
                .foregroundColor(.white)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCheckInConfirmation = false
                }
                switchTab(to: .people, source: .user)
            } label: {
                Text("See who’s here")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(VisualStyle.primaryAction))
            }
            .buttonStyle(PressableScaleButtonStyle())
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
