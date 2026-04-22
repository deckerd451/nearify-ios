import SwiftUI

struct ExploreView: View {
    @Binding var selectedTab: AppTab

    @ObservedObject private var explore = ExploreEventsService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var modeState = EventModeState.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var advertiser = BLEAdvertiserService.shared
    @ObservedObject private var authService = AuthService.shared

    @State private var showScanner = false
    @State private var showLeaveConfirmation = false
    @State private var expandedEventId: UUID?
    @State private var selectedPastEvent: ExploreEvent?

    enum ExploreJoinState: Equatable {
        case idle
        case joining(eventId: String)
        case joined(eventName: String)
        case failed(message: String)
    }

    @State private var joinState: ExploreJoinState = .idle

    fileprivate enum SectionRole {
        case upcoming
        case happeningNow
        case rejoin
    }

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
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(
                    selectedTab: $selectedTab,
                    onSuccess: { _ in
                        showScanner = false
                        explore.refresh()
                    },
                    onCancel: {
                        showScanner = false
                    }
                )
            }
            .confirmationDialog(
                "Leave Event",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Event", role: .destructive) {
                    Task { await eventJoin.leaveEvent() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your connections and messages will be kept.")
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
                currentEventSection
                reconnectSection
                eventListsSection
                emptyStateSection
                scanFallback
            }
            .padding(.top, DesignTokens.titleToContent)
            .padding(.bottom, DesignTokens.scrollBottomPadding)
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
        if case .left = modeState.membership {
            exitedBanner
        }

        if let error = explore.loadError, noSections {
            errorBanner(error)
        }
    }

    @ViewBuilder
    private var currentEventSection: some View {
        if let current = explore.currentEvent {
            CurrentEventCardView(
                event: current,
                isExpanded: expandedEventId == current.id,
                attendeeCount: attendeesService.attendeeCount,
                isJoined: {
                    if case .joined = modeState.membership { return true }
                    return false
                }(),
                isInEvent: {
                    if case .inEvent = modeState.membership { return true }
                    return false
                }(),
                liveIndicatorText: modeState.membership.isParticipating
                    ? UserPresenceStateResolver.exploreLiveIndicator
                    : "Joined · Ready to check in",
                liveIndicatorColor: modeState.membership.isParticipating
                    ? UserPresenceStateResolver.statusColor
                : Color.blue,
                isHostAnchorMode: advertiser.isHostAnchorMode,
                onToggleExpand: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        expandedEventId = expandedEventId == current.id ? nil : current.id
                    }
                },
                onCheckIn: {
                    Task {
                        await eventJoin.checkIn()
                        selectedTab = .home
                    }
                },
                onSayGoodbye: {
                    showLeaveConfirmation = true
                },
                onEnableAnchor: {
                    advertiser.enableHostAnchorMode()
                },
                onDisableAnchor: {
                    advertiser.disableHostAnchorMode()
                },
                currentUserProfileId: authService.currentUser?.id
            )
        }
    }

    @ViewBuilder
    private var reconnectSection: some View {
        if explore.currentEvent == nil && !modeState.membership.isParticipating {
            if let ctx = eventJoin.reconnectContext {
                ReconnectBannerView(
                    eventName: ctx.eventName,
                    eventId: ctx.eventId,
                    joinState: joinState,
                    onRejoin: {
                        performJoin(eventId: ctx.eventId)
                    },
                    onDismiss: {
                        eventJoin.dismissReconnect()
                    }
                )
                .padding(.horizontal)
            }
        }
    }

    private var eventListsSection: some View {
        VStack(spacing: DesignTokens.sectionSpacing) {
            if !explore.upcoming.isEmpty {
                EventSectionView(
                    title: "Upcoming",
                    icon: "calendar",
                    iconColor: .blue,
                    events: explore.upcoming,
                    role: .upcoming,
                    expandedEventId: $expandedEventId,
                    joinState: joinState,
                    currentJoinedEventId: eventJoin.currentEventID,
                    isEventJoined: eventJoin.isEventJoined,
                    onJoin: { eventId in
                        performJoin(eventId: eventId)
                    },
                    pastEventPreview: { _ in nil },
                    canRejoin: { _ in false },
                    onPastEventTap: { _ in }
                )
            }

            if !explore.happeningNow.isEmpty {
                EventSectionView(
                    title: "Live Now",
                    icon: "circle.fill",
                    iconColor: .green,
                    events: explore.happeningNow,
                    role: .happeningNow,
                    expandedEventId: $expandedEventId,
                    joinState: joinState,
                    currentJoinedEventId: eventJoin.currentEventID,
                    isEventJoined: eventJoin.isEventJoined,
                    onJoin: { eventId in
                        performJoin(eventId: eventId)
                    },
                    pastEventPreview: { _ in nil },
                    canRejoin: { _ in false },
                    onPastEventTap: { _ in }
                )
            }

            if !explore.recent.isEmpty {
                EventSectionView(
                    title: "Past Events",
                    icon: "arrow.counterclockwise",
                    iconColor: .orange,
                    events: explore.recent,
                    role: .rejoin,
                    expandedEventId: $expandedEventId,
                    joinState: joinState,
                    currentJoinedEventId: eventJoin.currentEventID,
                    isEventJoined: eventJoin.isEventJoined,
                    onJoin: { eventId in
                        performJoin(eventId: eventId)
                    },
                    pastEventPreview: { event in
                        pastEventPreview(for: event)
                    },
                    canRejoin: { event in
                        canRejoinPastEvent(event)
                    },
                    onPastEventTap: { event in
                        selectedPastEvent = event
                    }
                )
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

    private func pastEventPreview(for event: ExploreEvent) -> PastEventPreview? {
        guard let summary = summaryForPastEvent(event) else {
            return PastEventPreview(
                line: "Summary available soon",
                snippet: nil
            )
        }

        let line: String
        if let strongest = summary.strongestInteraction {
            line = "Strongest: \(strongest.name)"
        } else if summary.snapshot.meaningfulPeopleCount == 0 {
            line = "No meaningful contacts"
        } else {
            let count = summary.snapshot.meaningfulPeopleCount
            line = "\(count) meaningful \(count == 1 ? "contact" : "contacts")"
        }

        let snippet = summary.followUpSuggestions.first?.reason ?? summary.snapshot.activityLine

        return PastEventPreview(
            line: line,
            snippet: snippet
        )
    }

    private func performJoin(eventId: String) {
        guard joinState == .idle else {
            #if DEBUG
            print("[Explore] ⛔ Join blocked — already in state: \(joinState)")
            #endif
            return
        }

        if eventJoin.isEventJoined && eventJoin.currentEventID == eventId {
            #if DEBUG
            print("[Explore] ⛔ Already joined event \(eventId) — skipping")
            #endif
            return
        }

        joinState = .joining(eventId: eventId)

        Task {
            await eventJoin.joinEvent(eventID: eventId)

            await MainActor.run {
                if eventJoin.pendingEventSwitch != nil {
                    joinState = .idle
                    #if DEBUG
                    print("[Explore] ℹ️ Event switch confirmation required — resetting join state")
                    #endif
                    return
                }

                if eventJoin.isEventJoined {
                    let name = eventJoin.currentEventName ?? "the event"
                    joinState = .joined(eventName: name)

                    #if DEBUG
                    print("[Explore] ✅ Join succeeded — showing confirmation")
                    #endif

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if case .joined = joinState {
                            joinState = .idle
                        }
                    }
                } else {
                    let error = eventJoin.joinError ?? "Something went wrong"
                    joinState = .failed(message: error)

                    #if DEBUG
                    print("[Explore] ❌ Join failed: \(error)")
                    #endif

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if case .failed = joinState {
                            joinState = .idle
                        }
                    }
                }
            }
        }
    }

    private func joinSuccessBanner(eventName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("You're in")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("Joined \(eventName)")
                    .font(.caption)
                    .foregroundColor(.gray)

                Text("Check in when you arrive")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
            }

            Spacer()
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

    private var exitedBanner: some View {
        let state = modeState.membership

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.iconName)
                    .foregroundColor(state.displayColor)

                Text(state.displayLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(state.displayColor)
            }

            if let name = state.eventName {
                Text(name)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }

            Text("Your connections and messages are still available.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button {
                eventJoin.acknowledgeExit()
            } label: {
                Text("OK")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal)
    }

    private var scanFallback: some View {
        VStack(spacing: 10) {
            Text("Don't see your event?")
                .font(.caption)
                .foregroundColor(.gray)

            Button {
                showScanner = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.caption)
                    Text("Scan Event QR")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
            }
        }
        .padding(.top, 8)
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

// MARK: - Current Event Card

private struct CurrentEventCardView: View {
    let event: ExploreEvent
    let isExpanded: Bool
    let attendeeCount: Int
    let isJoined: Bool
    let isInEvent: Bool
    let liveIndicatorText: String
    let liveIndicatorColor: Color
    let isHostAnchorMode: Bool

    let onToggleExpand: () -> Void
    let onCheckIn: () -> Void
    let onSayGoodbye: () -> Void
    let onEnableAnchor: () -> Void
    let onDisableAnchor: () -> Void
    let currentUserProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.name)
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 4) {
                Circle()
                    .fill(liveIndicatorColor)
                    .frame(width: 6, height: 6)

                Text(liveIndicatorText)
                    .font(.caption2)
                    .foregroundColor(liveIndicatorColor.opacity(0.8))
            }

            EventMetadataRow(
                dateDisplay: event.dateDisplay,
                location: event.location,
                expanded: isExpanded
            )

            if isExpanded {
                if let desc = event.eventDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }

                let brief = PreEventBriefBuilder.build(
                    eventId: event.id,
                    eventName: event.name
                )

                let hasBriefContent = !brief.hereNow.isEmpty ||
                    !brief.likelyAttendees.isEmpty ||
                    !brief.conversationStarters.isEmpty ||
                    !brief.peopleToMeet.isEmpty

                if hasBriefContent {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)

                    PreEventBriefView(brief: brief)
                }
            }

            let attendeeLabel = UserPresenceStateResolver.exploreAttendeeLabel(count: attendeeCount)
            if !attendeeLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text(attendeeLabel)
                }
                .font(.caption)
                .foregroundColor(.green.opacity(0.8))
            }

            if isInEvent {
                Divider()
                    .background(Color.white.opacity(0.1))

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Host Anchor Mode")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)

                        Text(
                            isHostAnchorMode
                                ? "Broadcasting as event anchor"
                                : "Broadcast this phone as the event anchor"
                        )
                        .font(.caption2)
                        .foregroundColor(.gray)
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isHostAnchorMode },
                            set: { newValue in
                                if newValue {
                                    onEnableAnchor()
                                } else {
                                    onDisableAnchor()
                                }
                            }
                        )
                    )
                    .labelsHidden()
                }
            }

            if isJoined {
                Button(action: onCheckIn) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))

                        Text("Check In")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.green))
                }
                .padding(.top, 4)
            }

            if isInEvent {
                Button(action: onSayGoodbye) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12))

                        Text("Say Goodbye")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(.top, 4)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            EventJoinQRCard(
                eventId: event.id,
                eventName: event.name
            )

            PersonalConnectQRCard(
                title: "Connect with me",
                subtitle: "Let anyone here connect with you instantly — even without the app.",
                eventId: event.id,
                profileId: currentUserProfileId
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
        .padding(.horizontal)
    }
}

// MARK: - Event Section

private struct EventSectionView: View {
    let title: String
    let icon: String
    let iconColor: Color
    let events: [ExploreEvent]
    let role: ExploreView.SectionRole

    @Binding var expandedEventId: UUID?

    let joinState: ExploreView.ExploreJoinState
    let currentJoinedEventId: String?
    let isEventJoined: Bool

    let onJoin: (String) -> Void
    let pastEventPreview: (ExploreEvent) -> PastEventPreview?
    let canRejoin: (ExploreEvent) -> Bool
    let onPastEventTap: (ExploreEvent) -> Void

    var body: some View {
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
                EventCardView(
                    event: event,
                    role: role,
                    isExpanded: expandedEventId == event.id,
                    preview: pastEventPreview(event),
                    canRejoin: canRejoin(event),
                    joinState: joinState,
                    currentJoinedEventId: currentJoinedEventId,
                    isEventJoined: isEventJoined,
                    onTap: {
                        if role == .rejoin {
                            onPastEventTap(event)
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                expandedEventId = expandedEventId == event.id ? nil : event.id
                            }
                        }
                    },
                    onJoin: {
                        onJoin(event.id.uuidString)
                    }
                )
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Event Card

private struct EventCardView: View {
    let event: ExploreEvent
    let role: ExploreView.SectionRole
    let isExpanded: Bool
    let preview: PastEventPreview?
    let canRejoin: Bool
    let joinState: ExploreView.ExploreJoinState
    let currentJoinedEventId: String?
    let isEventJoined: Bool

    let onTap: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            EventMetadataRow(
                dateDisplay: event.dateDisplay,
                location: event.location,
                expanded: isExpanded
            )

            if let desc = event.eventDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(isExpanded ? nil : 2)
            }

            if event.activeAttendeeCount > 0 && event.isHappeningNow {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("\(event.activeAttendeeCount) here now")
                }
                .font(.caption)
                .foregroundColor(.green.opacity(0.8))
            }

            if let preview {
                PastEventPreviewView(preview: preview)
            }

            if isExpanded && role != .rejoin {
                let brief = PreEventBriefBuilder.build(
                    eventId: event.id,
                    eventName: event.name
                )

                let hasBriefContent = !brief.hereNow.isEmpty ||
                    !brief.likelyAttendees.isEmpty ||
                    !brief.conversationStarters.isEmpty ||
                    !brief.peopleToMeet.isEmpty

                if hasBriefContent {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)

                    PreEventBriefView(brief: brief)
                }
            }

            EventCardActionRow(
                role: role,
                eventId: event.id.uuidString,
                joinState: joinState,
                currentJoinedEventId: currentJoinedEventId,
                isEventJoined: isEventJoined,
                canRejoin: canRejoin,
                onJoin: onJoin
            )
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

// MARK: - Shared Bits

private struct EventMetadataRow: View {
    let dateDisplay: String?
    let location: String?
    let expanded: Bool

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
                .lineLimit(expanded ? nil : 1)
            }

            if let location, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                    Text(location)
                }
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(expanded ? nil : 1)
            }
        }
    }
}

private struct PastEventPreview {
    let line: String
    let snippet: String?
}

private struct PastEventPreviewView: View {
    let preview: PastEventPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.9))

                Text(preview.line)
                    .font(.caption)
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(1)
            }

            if let snippet = preview.snippet {
                Text(snippet)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
    }
}

private struct EventCardActionRow: View {
    let role: ExploreView.SectionRole
    let eventId: String
    let joinState: ExploreView.ExploreJoinState
    let currentJoinedEventId: String?
    let isEventJoined: Bool
    let canRejoin: Bool
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch role {
            case .upcoming, .happeningNow:
                joinButton
            case .rejoin:
                if canRejoin {
                    rejoinButton
                }
            }
        }
    }

    private var isThisJoining: Bool {
        joinState == .joining(eventId: eventId)
    }

    private var isAlreadyJoined: Bool {
        isEventJoined && currentJoinedEventId == eventId
    }

    private var joinButton: some View {
        Group {
            if isAlreadyJoined {
                joinedConfirmationButton
            } else {
                Button(action: onJoin) {
                    HStack(spacing: 5) {
                        if isThisJoining {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption)
                        }

                        Text(isThisJoining ? "Joining…" : "Join")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isThisJoining ? Color.green.opacity(0.6) : Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }
                .disabled(joinState != .idle)
            }
        }
    }

    private var rejoinButton: some View {
        Group {
            if isAlreadyJoined {
                joinedConfirmationButton
            } else {
                Button(action: onJoin) {
                    HStack(spacing: 5) {
                        if isThisJoining {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.caption)
                        }

                        Text(isThisJoining ? "Joining…" : "Rejoin")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isThisJoining ? Color.orange.opacity(0.6) : Color.orange)
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }
                .disabled(joinState != .idle)
            }
        }
    }

    private var joinedConfirmationButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)

            Text("Joined")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.15))
        .foregroundColor(.green)
        .cornerRadius(8)
    }
}

// MARK: - Reconnect Banner

private struct ReconnectBannerView: View {
    let eventName: String
    let eventId: String
    let joinState: ExploreView.ExploreJoinState
    let onRejoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reconnect to \(eventName)?")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)

                    Text("You were at this event recently")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
            }

            HStack(spacing: 12) {
                Button(action: onRejoin) {
                    HStack(spacing: 5) {
                        if joinState == .joining(eventId: eventId) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }

                        Text(joinState == .joining(eventId: eventId) ? "Joining…" : "Rejoin")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .cornerRadius(10)
                }
                .disabled(joinState != .idle)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Past Event Recap Sheet

private struct PastEventRecapView: View {
    let event: ExploreEvent
    let summary: PostEventSummary?
    let canRejoin: Bool
    let onRejoin: () -> Void

    @Environment(\.dismiss) private var dismiss

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

                        if let summary {
                            PostEventSummaryView(
                                summary: summary,
                                onMessage: { _ in },
                                onViewProfile: { _ in }
                            )
                            .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
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
    }
}
