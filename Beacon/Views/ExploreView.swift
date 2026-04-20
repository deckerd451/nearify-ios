import SwiftUI

struct ExploreView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var explore = ExploreEventsService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var modeState = EventModeState.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var advertiser = BLEAdvertiserService.shared

    @State private var showScanner = false
    @State private var showLeaveConfirmation = false

    // MARK: - Join State
    //
    // Tracks the join flow to prevent double-taps and show clear feedback.
    // Only one join can be in progress at a time.

    enum ExploreJoinState: Equatable {
        case idle
        case joining(eventId: String)
        case joined(eventName: String)
        case failed(message: String)
    }

    @State private var joinState: ExploreJoinState = .idle
    @State private var expandedEventId: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if explore.isLoading && noSections {
                    ScrollView { loadingState.frame(maxWidth: .infinity) }
                } else {
                    mainContent
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { explore.refresh() }
            .onAppear { explore.refresh() }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(
                    selectedTab: $selectedTab,
                    onSuccess: { _ in
                        showScanner = false
                        explore.refresh()
                    },
                    onCancel: { showScanner = false }
                )
            }
            .confirmationDialog("Leave Event", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave Event", role: .destructive) { Task { await eventJoin.leaveEvent() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your connections and messages will be kept.")
            }
        }
    }

    private var noSections: Bool {
        explore.currentEvent == nil
        && explore.happeningNow.isEmpty
        && explore.upcoming.isEmpty
        && explore.recent.isEmpty
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: DesignTokens.sectionSpacing) {
                // Join success confirmation — shown briefly after successful join
                if case .joined(let eventName) = joinState {
                    joinSuccessBanner(eventName: eventName)
                }

                // Join failure — shown briefly after failed join
                if case .failed(let message) = joinState {
                    joinFailedBanner(message: message)
                }

                // Exited state banner (left only — dormant shows Resume UI elsewhere)
                if case .left = modeState.membership { exitedBanner }

                // Error state
                if let error = explore.loadError, noSections {
                    errorBanner(error)
                }

                // ── STRICT HIERARCHY ──

                // 1. JOINED EVENT (guest list / intent) — always first
                if let current = explore.currentEvent {
                    currentEventCard(current)
                }

                // 2. Reconnect banner (only when NOT in an event)
                if explore.currentEvent == nil && !modeState.membership.isParticipating {
                    reconnectBanner
                }

                // 3. UPCOMING (primary discovery surface)
                if !explore.upcoming.isEmpty {
                    eventSection(
                        title: "Upcoming",
                        icon: "calendar",
                        iconColor: .blue,
                        events: explore.upcoming,
                        sectionRole: .upcoming
                    )
                }

                // 4. LIVE NOW (secondary to upcoming)
                if !explore.happeningNow.isEmpty {
                    eventSection(
                        title: "Live Now",
                        icon: "circle.fill",
                        iconColor: .green,
                        events: explore.happeningNow,
                        sectionRole: .happeningNow
                    )
                }

                // 5. PAST EVENTS (visually secondary)
                if !explore.recent.isEmpty {
                    eventSection(
                        title: "Past Events",
                        icon: "arrow.counterclockwise",
                        iconColor: .orange,
                        events: explore.recent,
                        sectionRole: .rejoin
                    )
                }

                // 6. Empty state
                if noSections && explore.loadError == nil {
                    emptyEventsMessage
                }

                // 7. QR fallback (always present)
                scanFallback
            }
            .padding(.top, DesignTokens.titleToContent)
            .padding(.bottom, DesignTokens.scrollBottomPadding)
        }
    }

    // MARK: - Section Role

    private enum SectionRole {
        case happeningNow, upcoming, rejoin
    }

    // MARK: - Current Event Card

    private func currentEventCard(_ event: ExploreEvent) -> some View {
        let isExpanded = expandedEventId == event.id

        return VStack(alignment: .leading, spacing: 10) {
            // Event name
            Text(event.name)
                .font(.headline)
                .foregroundColor(.white)

            // Live indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(modeState.membership.isParticipating ? UserPresenceStateResolver.statusColor : Color.blue)
                    .frame(width: 6, height: 6)
                Text(modeState.membership.isParticipating ? UserPresenceStateResolver.exploreLiveIndicator : "Joined · Ready to check in")
                    .font(.caption2)
                    .foregroundColor((modeState.membership.isParticipating ? UserPresenceStateResolver.statusColor : .blue).opacity(0.8))
            }

            // Date / location — truncated when collapsed, full when expanded
            HStack(spacing: 12) {
                if let date = event.dateDisplay {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(date)
                    }
                    .font(.caption).foregroundColor(.gray)
                    .lineLimit(isExpanded ? nil : 1)
                }
                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 10))
                        Text(location)
                    }
                    .font(.caption).foregroundColor(.gray)
                    .lineLimit(isExpanded ? nil : 1)
                }
            }

            // Expanded: full description + pre-event brief
            if isExpanded {
                if let desc = event.eventDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                }

                let brief = PreEventBriefBuilder.build(
                    eventId: event.id,
                    eventName: event.name
                )
                let hasBriefContent = !brief.hereNow.isEmpty
                    || !brief.likelyAttendees.isEmpty
                    || !brief.conversationStarters.isEmpty
                    || !brief.peopleToMeet.isEmpty

                if hasBriefContent {
                    Divider().background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)

                    PreEventBriefView(brief: brief)
                }
            }

            // Attendee count
            let attendeeLabel = UserPresenceStateResolver.exploreAttendeeLabel(count: attendeesService.attendeeCount)
            if !attendeeLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text(attendeeLabel)
                }
                .font(.caption).foregroundColor(.green.opacity(0.8))
            }

            // Host Anchor Mode — only when actively in event
            if case .inEvent = modeState.membership {
                Divider().background(Color.white.opacity(0.1))

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Host Anchor Mode")
                            .font(.caption).fontWeight(.medium).foregroundColor(.white)
                        Text(advertiser.isHostAnchorMode
                             ? "Broadcasting as event anchor"
                             : "Broadcast this phone as the event anchor")
                            .font(.caption2).foregroundColor(.gray)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { advertiser.isHostAnchorMode },
                        set: { $0 ? advertiser.enableHostAnchorMode() : advertiser.disableHostAnchorMode() }
                    ))
                    .labelsHidden()
                }
            }

            if case .joined = modeState.membership {
                Button {
                    Task {
                        await eventJoin.checkIn()
                        selectedTab = .home
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 12))
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

            // Leave button (Say Goodbye)
            if case .inEvent = modeState.membership {
                Button { showLeaveConfirmation = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle").font(.system(size: 12))
                        Text("Say Goodbye").font(.caption).fontWeight(.medium)
                    }
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
                }
                .padding(.top, 4)
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
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                expandedEventId = isExpanded ? nil : event.id
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Reconnect Banner

    @ViewBuilder
    private var reconnectBanner: some View {
        if let ctx = eventJoin.reconnectContext {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title3).foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reconnect to \(ctx.eventName)?")
                            .font(.subheadline).fontWeight(.medium).foregroundColor(.white)
                        Text("You were at this event recently")
                            .font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button {
                        performJoin(eventId: ctx.eventId)
                    } label: {
                        HStack(spacing: 5) {
                            if joinState == .joining(eventId: ctx.eventId) {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(joinState == .joining(eventId: ctx.eventId) ? "Joining…" : "Rejoin")
                                .font(.subheadline).fontWeight(.semibold)
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity)
                        .padding(.vertical, 10).background(Color.orange).cornerRadius(10)
                    }
                    .disabled(joinState != .idle)

                    Button {
                        eventJoin.dismissReconnect()
                    } label: {
                        Text("Dismiss").font(.subheadline).foregroundColor(.gray)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.white.opacity(0.08)).cornerRadius(10)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            )
            .padding(.horizontal)
        }
    }

    // MARK: - Exited Banner

    private var exitedBanner: some View {
        VStack(spacing: 10) {
            let s = modeState.membership
            HStack(spacing: 8) {
                Image(systemName: s.iconName).foregroundColor(s.displayColor)
                Text(s.displayLabel).font(.caption).fontWeight(.medium).foregroundColor(s.displayColor)
            }
            if let name = s.eventName {
                Text(name).font(.subheadline).foregroundColor(.white.opacity(0.6))
            }
            Text("Your connections and messages are still available.")
                .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
            Button { eventJoin.acknowledgeExit() } label: {
                Text("OK").font(.subheadline).fontWeight(.medium).foregroundColor(.white)
                    .padding(.horizontal, 32).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
        .padding(.horizontal)
    }

    // MARK: - Event Section

    private func eventSection(
        title: String,
        icon: String,
        iconColor: Color,
        events: [ExploreEvent],
        sectionRole: SectionRole
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.elementSpacing) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundColor(iconColor)
                Text(title.uppercased())
                    .font(.caption).fontWeight(.bold).foregroundColor(iconColor).tracking(1.2)
            }
            .padding(.horizontal)

            ForEach(events) { event in
                eventCard(event, role: sectionRole)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Event Card

    private func eventCard(_ event: ExploreEvent, role: SectionRole) -> some View {
        let relevance = (role != .rejoin) ? EventRelevanceScorer.score(event: event) : nil
        let isExpanded = expandedEventId == event.id

        return VStack(alignment: .leading, spacing: 10) {
            Text(event.name)
                .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)

            // Date / location — truncated when collapsed, full when expanded
            HStack(spacing: 12) {
                if let date = event.dateDisplay {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(date)
                    }
                    .font(.caption).foregroundColor(.gray)
                    .lineLimit(isExpanded ? nil : 1)
                }
                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 10))
                        Text(location)
                    }
                    .font(.caption).foregroundColor(.gray)
                    .lineLimit(isExpanded ? nil : 1)
                }
            }

            // Description — collapsed: 2 lines, expanded: full
            if let desc = event.eventDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption).foregroundColor(.white.opacity(0.6))
                    .lineLimit(isExpanded ? nil : 2)
            }

            // Relevance reason
            if let rel = relevance {
                HStack(spacing: 5) {
                    Image(systemName: rel.mode == .reinforcement ? "person.2" : "sparkles")
                        .font(.system(size: 10))
                    Text(rel.reason)
                        .font(.caption)
                        .lineLimit(isExpanded ? nil : 1)
                }
                .foregroundColor(rel.mode == .reinforcement ? .orange.opacity(0.8) : .cyan.opacity(0.8))
            }

            if event.activeAttendeeCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(event.activeAttendeeCount) here now")
                }
                .font(.caption).foregroundColor(.green.opacity(0.8))
            }

            // ── PRE-EVENT BRIEF (expanded only) ──
            if isExpanded {
                let brief = PreEventBriefBuilder.build(
                    eventId: event.id,
                    eventName: event.name
                )
                let hasBriefContent = !brief.hereNow.isEmpty
                    || !brief.likelyAttendees.isEmpty
                    || !brief.conversationStarters.isEmpty
                    || !brief.peopleToMeet.isEmpty

                if hasBriefContent {
                    Divider().background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)

                    PreEventBriefView(brief: brief)
                }
            }

            // CTA — determined by section role
            HStack(spacing: 10) {
                switch role {
                case .happeningNow, .upcoming:
                    joinButton(eventId: event.id.uuidString)
                case .rejoin:
                    rejoinButton(eventId: event.id.uuidString)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    role == .happeningNow ? Color.green.opacity(0.2) :
                    role == .rejoin ? Color.orange.opacity(0.2) :
                    Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                expandedEventId = isExpanded ? nil : event.id
            }
        }
    }

    // MARK: - CTAs

    private func joinButton(eventId: String) -> some View {
        let isThisJoining = joinState == .joining(eventId: eventId)
        let isAlreadyJoined = eventJoin.isEventJoined && eventJoin.currentEventID == eventId

        return Group {
            if isAlreadyJoined {
                // Already joined this event — show confirmation, not Join
                joinedConfirmationButton
            } else {
                Button {
                    performJoin(eventId: eventId)
                } label: {
                    HStack(spacing: 5) {
                        if isThisJoining {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: "arrow.right.circle.fill").font(.caption)
                        }
                        Text(isThisJoining ? "Joining…" : "Join")
                            .font(.subheadline).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(isThisJoining ? Color.green.opacity(0.6) : Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }
                .disabled(joinState != .idle)
            }
        }
    }

    private func rejoinButton(eventId: String) -> some View {
        let isThisJoining = joinState == .joining(eventId: eventId)
        let isAlreadyJoined = eventJoin.isEventJoined && eventJoin.currentEventID == eventId

        return Group {
            if isAlreadyJoined {
                joinedConfirmationButton
            } else {
                Button {
                    performJoin(eventId: eventId)
                } label: {
                    HStack(spacing: 5) {
                        if isThisJoining {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: "arrow.counterclockwise.circle.fill").font(.caption)
                        }
                        Text(isThisJoining ? "Joining…" : "Rejoin")
                            .font(.subheadline).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(isThisJoining ? Color.orange.opacity(0.6) : Color.orange)
                    .foregroundColor(.black)
                    .cornerRadius(8)
                }
                .disabled(joinState != .idle)
            }
        }
    }

    /// Shown after a successful join — replaces the Join/Rejoin button.
    private var joinedConfirmationButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").font(.caption)
            Text("Joined")
                .font(.subheadline).fontWeight(.semibold)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.green.opacity(0.15))
        .foregroundColor(.green)
        .cornerRadius(8)
    }

    // MARK: - Join Handler

    /// Single entry point for all join actions in Explore.
    /// Guards against double-taps, shows loading state, handles success/failure.
    private func performJoin(eventId: String) {
        // Guard: already joining something
        guard joinState == .idle else {
            #if DEBUG
            print("[Explore] ⛔ Join blocked — already in state: \(joinState)")
            #endif
            return
        }

        // Guard: already joined this event
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
                // If a pending event switch was triggered, the join was blocked
                // by the event ownership guard. Reset to idle — the confirmation
                // dialog (in BeaconApp) will handle the rest.
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

                // Keep user in Explore after join so they can explicitly check in.
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

                    // Reset after showing error briefly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if case .failed = joinState {
                            joinState = .idle
                        }
                    }
                }
            }
        }
    }

    // MARK: - Join Feedback Banners

    private func joinSuccessBanner(eventName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're in")
                    .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                Text("Joined \(eventName)")
                    .font(.caption).foregroundColor(.gray)
                Text("Check in when you arrive")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.3), lineWidth: 1))
        )
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func joinFailedBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3).foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't join")
                    .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                Text(message)
                    .font(.caption).foregroundColor(.gray).lineLimit(2)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.3), lineWidth: 1))
        )
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - QR Fallback

    private var scanFallback: some View {
        VStack(spacing: 10) {
            Text("Don't see your event?").font(.caption).foregroundColor(.gray)
            Button { showScanner = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder").font(.caption)
                    Text("Scan Event QR").font(.subheadline).fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.white.opacity(0.08)).cornerRadius(10)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading events…").font(.subheadline).foregroundColor(.gray)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                Text("Couldn't load events").font(.subheadline).foregroundColor(.white)
            }
            Text(error).font(.caption).foregroundColor(.gray).lineLimit(2)
            Button { explore.refresh() } label: {
                Text("Try again").font(.caption).fontWeight(.medium).foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .padding(.horizontal)
    }

    private var emptyEventsMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36)).foregroundColor(.gray.opacity(0.5))
            Text("No public events right now")
                .font(.subheadline).foregroundColor(.white.opacity(0.7))
            Text("Events will appear here as they're created.")
                .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
    }
}
