import SwiftUI

/// Maslow-aligned intelligence surface.
/// Renders sections in strict order: CONTINUE → INSIGHTS → NEXT MOVES.
/// Shows minimal UI when nothing meets timing + signal thresholds.
/// Reacts immediately when the user takes action.
struct HomeSurfaceView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var surface = HomeSurfaceService.shared
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared

    @State private var activeConversation: ConversationDestination?
    @State private var showNotConnectedAlert = false
    @State private var isOpeningConversation = false
    @State private var isConnecting = false
    @State private var navigationPath = NavigationPath()
    @State private var findAttendeeTarget: EventAttendee?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                if surface.isLoading && surface.isEmpty {
                    loadingState
                } else if surface.isEmpty {
                    emptyState
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
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: FeedRoute.self) { route in
                switch route {
                case .profileDetail(let profileId):
                    FeedProfileDetailView(profileId: profileId)
                }
            }
            .refreshable {
                feedService.requestRefresh(reason: "home-pull")
                try? await Task.sleep(nanoseconds: 500_000_000)
                surface.requestRefresh(reason: "home-pull")
            }
            .onAppear {
                feedService.requestRefresh(reason: "home-appear")
                surface.requestRefresh(reason: "home-appear")
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
            .sheet(item: $findAttendeeTarget) { attendee in
                FindAttendeeView(attendee: attendee)
            }
        }
    }

    // MARK: - Surface Content

    private var surfaceContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Event context strip (when live)
                if let eventName = surface.liveEventName {
                    eventContextStrip(eventName: eventName, attendeeCount: surface.liveAttendeeCount)
                }

                // CONTINUE — always first, visually dominant
                if !surface.continueItems.isEmpty {
                    sectionView(section: .continue, items: surface.continueItems, accentColor: .orange)
                }

                // INSIGHTS — only if meaningful
                if !surface.insightItems.isEmpty {
                    sectionView(section: .insights, items: surface.insightItems, accentColor: .purple)
                }

                // NEXT MOVES — only if meaningful
                if !surface.nextMoveItems.isEmpty {
                    sectionView(section: .nextMoves, items: surface.nextMoveItems, accentColor: .blue)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Event Context Strip

    private func eventContextStrip(eventName: String, attendeeCount: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(eventName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.9))
            if attendeeCount > 0 {
                Text("·")
                    .foregroundColor(.gray)
                Text("\(attendeeCount) here")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
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

            HStack(spacing: 12) {
                surfaceActionButton(item, accentColor: accentColor)

                if item.isFind, let profileId = item.profileId {
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundColor(.gray.opacity(0.4))

            if eventJoin.isEventJoined {
                Text("Nothing urgent right now.")
                    .font(.headline).foregroundColor(.white)
                Text("Check the Event tab to discover people nearby.")
                    .font(.subheadline).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                Text("Go to Event")
                    .fontWeight(.semibold).foregroundColor(.black)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
                    .onTapGesture { selectedTab = .event }
            } else {
                Text("Join an event to start building your network")
                    .font(.headline).foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("Your connections and encounters will appear here")
                    .font(.subheadline).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                Text("Scan to join event")
                    .fontWeight(.semibold).foregroundColor(.black)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
                    .onTapGesture { selectedTab = .scan }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading…").font(.subheadline).foregroundColor(.gray)
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
            selectedTab = .event
        case .viewProfile:
            if let profileId = item.profileId {
                handleViewProfile(profileId: profileId)
            }
        }
    }

    private func handleViewProfile(profileId: UUID) {
        navigationPath.append(FeedRoute.profileDetail(profileId: profileId))
    }

    private func handleFindAttendee(profileId: UUID) {
        let attendees = attendeesService.attendees
        if let attendee = attendees.first(where: { $0.id == profileId }) {
            findAttendeeTarget = attendee
            #if DEBUG
            print("[Surface] 📍 Find attendee: \(attendee.name) via sheet")
            #endif
        } else {
            selectedTab = .event
            #if DEBUG
            print("[Surface] 📍 Find attendee fallback: switching to Event tab")
            #endif
        }
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
