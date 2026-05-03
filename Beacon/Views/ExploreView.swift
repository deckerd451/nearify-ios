import SwiftUI

struct ExploreView: View {
    @Binding var selectedTab: AppTab

    @ObservedObject private var explore = ExploreEventsService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared

    @State private var selectedPastEvent: ExploreEvent?
    @State private var showSwitchConfirmation = false
    @State private var joinInFlightEventID: String?

    enum ExploreJoinState: Equatable {
        case idle
        case joined(eventName: String)
        case failed(message: String)
    }

    @State private var joinState: ExploreJoinState = .idle
    @State private var lastJoinedEventID: String?

    private var noSections: Bool {
        explore.currentEvent == nil &&
        explore.happeningNow.isEmpty &&
        explore.upcoming.isEmpty &&
        explore.recent.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if explore.isLoading && noSections {
                    ScrollView {
                        loadingState
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    mainContent
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                explore.refresh()
            }
            .onAppear {
                explore.refresh()
                lastJoinedEventID = eventJoin.currentEventID
            }
            .onChange(of: eventJoin.pendingEventSwitch) { _, pending in
                showSwitchConfirmation = pending != nil
                if pending == nil {
                    joinInFlightEventID = nil
                }
            }
            .onChange(of: eventJoin.currentEventID) { _, newEventID in
                guard eventJoin.isEventJoined else {
                    lastJoinedEventID = newEventID
                    return
                }

                guard newEventID != lastJoinedEventID else { return }
                lastJoinedEventID = newEventID

                guard newEventID != nil else { return }
                joinInFlightEventID = nil
                showJoinedBanner(eventName: eventJoin.currentEventName ?? "the event")
            }
            .confirmationDialog(
                "Switch Events?",
                isPresented: $showSwitchConfirmation,
                titleVisibility: .visible
            ) {
                if let pending = eventJoin.pendingEventSwitch {
                    Button("Leave \(pending.currentEventName) and Join Event \(pending.newEventName ?? "new event")", role: .destructive) {
                        Task { await eventJoin.confirmEventSwitch() }
                    }
                }
                Button("Cancel", role: .cancel) {
                    eventJoin.cancelEventSwitch()
                    joinInFlightEventID = nil
                }
            } message: {
                if let pending = eventJoin.pendingEventSwitch {
                    Text("You’re currently in \(pending.currentEventName). Confirm to switch to \(pending.newEventName ?? "the selected event").")
                }
            }
            .sheet(item: $selectedPastEvent) { event in
                PastEventRecapView(
                    event: event,
                    summary: summaryForPastEvent(event),
                    canRejoin: canRejoinPastEvent(event),
                    onRejoin: {
                        selectedPastEvent = nil
                        performJoin(eventId: event.id.uuidString)
                    }
                )
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: DesignTokens.sectionSpacing) {
                joinFeedbackSection
                statusBannerSection
                activeEventSection
                eventListsSection
                emptyStateSection
            }
            .padding(.top, DesignTokens.titleToContent)
            .padding(.bottom, DesignTokens.scrollBottomPadding)
        }
        .overlay(alignment: .top) {
            if eventJoin.isSwitchingEvent {
                switchingOverlay
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var joinFeedbackSection: some View {
        switch joinState {
        case .joined(let eventName):
            joinSuccessBanner(eventName: eventName)
        case .failed(let message):
            joinFailedBanner(message: message)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusBannerSection: some View {
        if let error = explore.loadError, noSections {
            errorBanner(error)
        }
    }

    @ViewBuilder
    private var activeEventSection: some View {
        if let current = explore.currentEvent {
            EventFocusCardView(
                title: current.name,
                statusText: eventJoin.isEventJoined ? "Live / Joined" : "Live",
                actionTitle: "Go to event",
                isPrimary: true,
                isActionDisabled: false,
                onAction: {
                    switchTab(to: .home)
                }
            )
            .padding(.horizontal)
        }
    }

    private var eventListsSection: some View {
        VStack(spacing: DesignTokens.sectionSpacing) {
            if !explore.happeningNow.isEmpty {
                eventSection(
                    title: "Live Now",
                    icon: "circle.fill",
                    iconColor: .green,
                    events: explore.happeningNow,
                    role: .happeningNow
                )
            }

            if !explore.upcoming.isEmpty {
                eventSection(
                    title: "Upcoming Events",
                    icon: "calendar",
                    iconColor: .blue,
                    events: explore.upcoming,
                    role: .upcoming
                )
            }

            if !explore.recent.isEmpty {
                eventSection(
                    title: "Past Events",
                    icon: "arrow.counterclockwise",
                    iconColor: .orange,
                    events: explore.recent,
                    role: .rejoin
                )
            }
        }
    }

    enum SectionRole {
        case upcoming
        case happeningNow
        case rejoin
    }

    private func eventSection(
        title: String,
        icon: String,
        iconColor: Color,
        events: [ExploreEvent],
        role: SectionRole
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.elementSpacing) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(iconColor)

                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(iconColor)
                    .tracking(1.2)
            }
            .padding(.horizontal)

            ForEach(events) { event in
                SimpleEventCardView(
                    event: event,
                    role: role,
                    isJoined: eventJoin.isEventJoined && eventJoin.currentEventID == event.id.uuidString,
                    isJoining: joinInFlightEventID == event.id.uuidString,
                    isJoinedElsewhere: eventJoin.isEventJoined && eventJoin.currentEventID != event.id.uuidString,
                    onJoin: {
                        if role == .rejoin {
                            selectedPastEvent = event
                        } else {
                            performJoin(eventId: event.id.uuidString)
                        }
                    },
                    onGoToEvent: {
                        switchTab(to: .home)
                    },
                    onOpenPastEvent: {
                        selectedPastEvent = event
                    }
                )
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        if noSections && explore.loadError == nil {
            emptyEventsMessage
        }
    }

    private func summaryForPastEvent(_ event: ExploreEvent) -> PostEventSummary? {
        guard let summary = eventJoin.postEventSummary else { return nil }
        return summary.eventName == event.name ? summary : nil
    }

    private func canRejoinPastEvent(_ event: ExploreEvent) -> Bool {
        eventJoin.reconnectContext?.eventId == event.id.uuidString
    }

    private func performJoin(eventId: String) {
        guard joinInFlightEventID == nil else { return }

        if eventJoin.isEventJoined && eventJoin.currentEventID == eventId {
            return
        }

        joinInFlightEventID = eventId

        let targetEventName = allEvents.first(where: { $0.id.uuidString == eventId })?.name

        Task {
            await eventJoin.joinEvent(eventID: eventId, eventName: targetEventName)

            await MainActor.run {
                if eventJoin.pendingEventSwitch != nil {
                    return
                }

                if eventJoin.isEventJoined {
                    if eventJoin.currentEventID == lastJoinedEventID {
                        showJoinedBanner(eventName: eventJoin.currentEventName ?? "the event")
                    }
                } else {
                    let error = eventJoin.joinError ?? "Something went wrong"
                    joinState = .failed(message: error)
                    joinInFlightEventID = nil

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if case .failed = joinState {
                            joinState = .idle
                        }
                    }
                }
            }
        }
    }

    private var allEvents: [ExploreEvent] {
        explore.happeningNow + explore.upcoming + explore.recent
    }

    private func showJoinedBanner(eventName: String) {
        joinState = .joined(eventName: eventName)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if case .joined = joinState {
                joinState = .idle
            }
        }
    }

    private func switchTab(to target: AppTab, source: TabChangeSource = .user) {
        _ = NavigationState.shared.requestTabChange(
            from: selectedTab,
            to: target,
            source: source,
            binding: &selectedTab
        )
    }

    private func joinSuccessBanner(eventName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("✓ Joined")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text(eventName)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            Button("Go to event") {
                switchTab(to: .home)
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.green))
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.green.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func joinFailedBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't join")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text("Loading events…")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }

    private var switchingOverlay: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Switching events…")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
                .overlay(
                    Capsule()
                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func errorBanner(_ error: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)

                Text("Couldn't load events")
                    .font(.subheadline)
                    .foregroundColor(.white)
            }

            Text(error)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(2)

            Button {
                explore.refresh()
            } label: {
                Text("Try again")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal)
    }

    private var emptyEventsMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.5))

            Text("No public events right now")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))

            Text("Events will appear here as they're created.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
    }
}

private struct EventFocusCardView: View {
    let title: String
    let statusText: String
    let actionTitle: String
    let isPrimary: Bool
    let isActionDisabled: Bool
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 6) {
                Circle()
                    .fill(isPrimary ? Color.green : Color.blue)
                    .frame(width: 7, height: 7)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor((isPrimary ? Color.green : Color.blue).opacity(0.85))
            }

            Button(actionTitle, action: onAction)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isPrimary ? Color.green : Color.blue))
                .disabled(isActionDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke((isPrimary ? Color.green : Color.blue).opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct SimpleEventCardView: View {
    let event: ExploreEvent
    let role: ExploreView.SectionRole
    let isJoined: Bool
    let isJoining: Bool
    let isJoinedElsewhere: Bool
    let onJoin: () -> Void
    let onGoToEvent: () -> Void
    let onOpenPastEvent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            EventMetadataRow(
                dateDisplay: event.dateDisplay,
                location: event.location
            )

            if let desc = event.eventDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }

            if role == .rejoin {
                Button("Open recap", action: onOpenPastEvent)
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                if isJoined {
                    HStack(spacing: 8) {
                        joinedBadge
                        Button("Go to event", action: onGoToEvent)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.green))
                    }
                } else {
                    Button(action: onJoin) {
                        HStack(spacing: 6) {
                            if isJoining {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.black)
                            }

                            Text(isJoining ? "Joining Event…" : (isJoinedElsewhere ? "Switch" : "Join Event"))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(role == .happeningNow ? Color.green : Color.blue))
                    }
                    .disabled(isJoining)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var joinedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
            Text("Joined")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundColor(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.green.opacity(0.12)))
    }

    private var borderColor: Color {
        switch role {
        case .happeningNow:
            return Color.green.opacity(0.2)
        case .rejoin:
            return Color.orange.opacity(0.2)
        case .upcoming:
            return Color.white.opacity(0.06)
        }
    }
}

private struct EventMetadataRow: View {
    let dateDisplay: String?
    let location: String?

    var body: some View {
        HStack(spacing: 12) {
            if let dateDisplay {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(dateDisplay)
                }
                .font(.caption)
                .foregroundColor(.gray)
            }

            if let location, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                    Text(location)
                }
                .font(.caption)
                .foregroundColor(.gray)
            }
        }
    }
}

private struct PastEventRecapView: View {
    let event: ExploreEvent
    let summary: PostEventSummary?
    let canRejoin: Bool
    let onRejoin: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var resolvedSummary: PostEventSummary?
    @State private var isLoadingFallback = false
    @State private var activeConversation: ExploreRecapConversationTarget?
    @State private var profileSheetTarget: ExploreRecapProfileSheetTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(event.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)

                        HStack(spacing: 12) {
                            if let date = event.dateDisplay {
                                Label(date, systemImage: "clock")
                            }

                            if let location = event.location, !location.isEmpty {
                                Label(location, systemImage: "mappin")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.gray)

                        if let recapSummary = resolvedSummary ?? summary {
                            PostEventSummaryView(
                                summary: recapSummary,
                                onMessage: { profileId in
                                    openConversation(profileId: profileId)
                                },
                                onViewProfile: { profileId in
                                    profileSheetTarget = ExploreRecapProfileSheetTarget(profileId: profileId)
                                }
                            )
                            .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                if isLoadingFallback {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text("Summary not ready yet")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("We’ll show event reflection here once a post-event summary is available.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.06))
                            )
                        }

                        if canRejoin {
                            Button(action: onRejoin) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                    Text("Rejoin Event")
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.orange)
                                .cornerRadius(10)
                            }
                            .padding(.top, 6)
                        }
                    }
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

        .task(id: event.id) {
            await loadFallbackIfNeeded()
        }
        .sheet(item: $activeConversation) { target in
            ConversationView(
                targetProfileId: target.profileId,
                preloadedConversation: target.conversation,
                preloadedName: target.name
            )
        }
    }



    @MainActor
    private func loadFallbackIfNeeded() async {
        if let summary {
            resolvedSummary = summary
            print("[RecapFallback] source=local summary for event \(event.id)")
            return
        }

        let inferredEnd = event.endsAt ?? event.startsAt?.addingTimeInterval(3 * 60 * 60)
        let isPastEvent = (inferredEnd ?? .distantFuture) < Date()
        guard isPastEvent else {
            print("[RecapFallback] unavailable: event not in past \(event.id)")
            return
        }

        isLoadingFallback = true
        defer { isLoadingFallback = false }

        if let fallback = await RecapFallbackService.shared.buildFallbackSummary(for: event) {
            resolvedSummary = fallback
            print("[RecapFallback] source=supabase fallback for event \(event.id)")
        } else {
            print("[RecapFallback] source=unavailable for event \(event.id)")
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
                activeConversation = ExploreRecapConversationTarget(
                    profileId: profileId,
                    name: targetName,
                    conversation: convo
                )
            }
        }
    }
}

private struct ExploreRecapProfileSheetTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
}

private struct ExploreRecapConversationTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let conversation: Conversation
}
