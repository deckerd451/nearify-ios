import SwiftUI
import Combine

enum AppTab: Int {
    case home = 0
    case people = 1
    case event = 2
    case profile = 3
    case messages = 4

    // Legacy aliases for backward compatibility
    static let eventMode = AppTab.event
    static let network = AppTab.event
    static let myQR = AppTab.profile
}

enum PeopleRoute: Hashable {
    case nearifyContacts
    case nearifyProfile(UUID)
}

struct MainTabView: View {
    let currentUser: User
    @Binding var selectedTab: AppTab

    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @StateObject private var contactShareService = ContactShareService.shared
    @State private var isConsumingPendingEvent = false
    @State private var incomingRequesterName = "Someone nearby"
    @State private var peopleNavigationPath = NavigationPath()
    @State private var lastHandledPeopleResetSignal = 0
    @State private var lastPendingRouteSignature: String?
    @State private var lastPeoplePathMutationSignature: String?
    @ObservedObject private var messaging = MessagingService.shared
    @ObservedObject private var navigationState = NavigationState.shared

    init(currentUser: User, selectedTab: Binding<AppTab>) {
        self.currentUser = currentUser
        self._selectedTab = selectedTab
        // Hide the system tab bar so the custom floating bar takes its place.
        // .safeAreaInset(edge: .bottom) in body renders the custom bar above
        // the home indicator; scrollable root tabs add their own centralized
        // clearance so their last content stays reachable above the overlay.
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
                    .nearifyTabHeader("Home")
            }
            .tag(AppTab.home)

            NavigationStack(path: $peopleNavigationPath) {
                PeopleView()
                    .nearifyTabHeader("People")
                    .navigationDestination(for: PeopleRoute.self) { route in
                        switch route {
                        case .nearifyContacts:
                            NearifyContactsView()
                        case .nearifyProfile(let profileId):
                            FeedProfileDetailView(profileId: profileId)
                        }
                    }
            }
            .tag(AppTab.people)

            NavigationStack {
                ExploreView(selectedTab: $selectedTab)
                    .nearifyTabHeader("Explore")
            }
            .tag(AppTab.event)

            NavigationStack {
                MyQRView(currentUser: currentUser)
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color.black, for: .navigationBar)
            }
            .tag(AppTab.profile)

            NavigationStack {
                MessagesHubView()
                    .nearifyTabHeader("Messages")
            }
            .tag(AppTab.messages)
        }
        .safeAreaInset(edge: .bottom) {
            CustomTabBar(
                selectedTab: $selectedTab,
                messagesUnreadCount: messaging.totalUnreadCount
            )
        }
        .onAppear {
            DebugLog.verbose("[Navigation] MainTabView appeared")
            ContactShareService.shared.start(for: currentUser.id)
            messaging.setMessagesTabActive(selectedTab == .messages)
            lastHandledPeopleResetSignal = navigationState.peopleSubrouteResetSignal
            replayPendingEventIfNeeded(source: "onAppear")
        }
        .onDisappear {
            ContactShareService.shared.stop()
        }
        .sheet(item: Binding(
            get: { contactShareService.incomingPendingRequest },
            set: { newValue in
                if newValue == nil {
                    contactShareService.incomingPendingRequest = nil
                }
            }
        )) { request in
            incomingRequestSheet(for: request)
        }
        .onChange(of: contactShareService.incomingPendingRequest?.id) { _, _ in
            Task {
                await refreshIncomingRequesterName()
            }
        }
        .onChange(of: currentUser.id) { _, newId in
            ContactShareService.shared.start(for: newId)
        }
        .onReceive(deepLinkManager.$pendingEventId.removeDuplicates()) { pendingEventId in
            guard pendingEventId != nil else { return }
            DebugLog.diagnostic("[NavigationFailure] pending event deep link received eventId=\(pendingEventId ?? "nil")")
            replayPendingEventIfNeeded(source: "onReceive")
        }
        .onReceive(deepLinkManager.$pendingProfileId.removeDuplicates()) { pendingProfileId in
            guard let pendingProfileId else { return }
            DebugLog.diagnostic("[NavigationFailure] pending profile deep link received profileId=\(pendingProfileId)")
            switchTab(to: .people, source: .user)
            NavigationState.shared.setPeopleFocusTarget(PeopleFocusTarget(
                profileId: pendingProfileId,
                source: "deepLink"
            )
            , source: "MainTabView.deepLinkProfile")
            _ = deepLinkManager.consumeProfileId()
        }

        .onReceive(navigationState.$pendingTabRoute.removeDuplicates()) { pendingTab in
            guard let pendingTab else { return }
            let signature = "\(selectedTab.rawValue)->\(pendingTab.rawValue)"
            if lastPendingRouteSignature == signature {
                DebugLog.verbose("[NavigationFrameDrop] kind=observerRoute reason=duplicateSignature source=MainTabView.pendingGlobalRoute signature=\(signature)")
                navigationState.consumePendingTabRouteIfMatching(pendingTab, source: "MainTabView.pendingGlobalRoute.duplicateDrop")
                return
            }
            lastPendingRouteSignature = signature

            guard selectedTab != pendingTab else {
                DebugLog.verbose("[NavigationFrameDrop] kind=observerRoute reason=alreadyOnRequestedTab source=MainTabView.pendingGlobalRoute requestedTab=\(pendingTab)")
                navigationState.consumePendingTabRouteIfMatching(pendingTab, source: "MainTabView.pendingGlobalRoute.alreadyOnRequestedTab")
                return
            }
            DebugLog.verbose("[NavigationObserverSource] source=MainTabView.pendingGlobalRoute currentTab=\(selectedTab) requestedTab=\(pendingTab) route=globalObserver")
            let didApply = navigationState.applyObserverTabRequest(
                current: selectedTab,
                requested: pendingTab,
                source: "MainTabView.pendingGlobalRoute",
                binding: &selectedTab
            )
            DispatchQueue.main.async {
                navigationState.consumePendingTabRouteIfMatching(
                    pendingTab,
                    source: didApply
                        ? "MainTabView.pendingGlobalRoute.consume.deferred"
                        : "MainTabView.pendingGlobalRoute.consume.deferredNoOp"
                )
            }
        }
        .onChange(of: navigationState.peopleSubrouteResetSignal) { _, newValue in
            guard newValue != lastHandledPeopleResetSignal else { return }
            lastHandledPeopleResetSignal = newValue
            guard !peopleNavigationPath.isEmpty else {
                DebugLog.verbose("[VisibleRouteGuard] ignored attendee refresh; route unchanged")
                return
            }
            let signature = "reset-\(newValue)-tab-\(selectedTab.rawValue)-count-\(peopleNavigationPath.count)"
            if lastPeoplePathMutationSignature == signature {
                DebugLog.verbose("[NavigationFrameCoalesce] source=MainTabView.peopleSubrouteReset sameFrameDuplicate=true signature=\(signature)")
                return
            }
            lastPeoplePathMutationSignature = signature
            DebugLog.verbose("[PathMutation] source=MainTabView.peopleSubrouteReset action=clearPath tab=\(selectedTab) count=\(peopleNavigationPath.count)")
            peopleNavigationPath = NavigationPath()
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            messaging.setMessagesTabActive(newValue == .messages)
            MessagingRefreshCoordinator.shared.requestRefresh(reason: .tabChange, mode: .quiet)
            DebugLog.verbose("[TabRouting] [TAB-WRITE] \(oldValue) -> \(newValue) source=MainTabView.TabViewBinding file=MainTabView")
            DebugLog.verbose("[PeopleNav] visible-route tab changed; activeTab=\(newValue)")
        }
        .onChange(of: peopleNavigationPath) { _, _ in
            DebugLog.verbose("[ViewRenderGuard] peopleNavigationPath changed; activeTab=\(selectedTab)")
        }
        .onChange(of: messaging.totalUnreadCount) { _, newCount in
            DebugLog.verbose("[MessagesBadge] unread count=\(newCount)")
        }
    }

    @ViewBuilder
    private func incomingRequestSheet(for request: ContactShareRequest) -> some View {
        VStack(spacing: 14) {
            Text("\(incomingRequesterName) wants to connect")
                .font(.headline)

            Text("You were nearby at \(EventJoinService.shared.currentEventName ?? "this event"). Share your approved contact info?")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button("Share Contact") {
                    Task {
                        await contactShareService.approve(request)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Not Now") {
                    Task {
                        await contactShareService.ignore(request)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .responsiveContentContainer(maxWidth: 520, compactPadding: 16, regularPadding: 24)
        .padding(.vertical, 24)
        .presentationDetents([.height(250)])
    }

    private func refreshIncomingRequesterName() async {
        guard let request = contactShareService.incomingPendingRequest else {
            await MainActor.run {
                incomingRequesterName = "Someone nearby"
            }
            return
        }

        if let profile = try? await ProfileService.shared.fetchProfileById(request.requesterProfileId) {
            await MainActor.run {
                incomingRequesterName = profile.name
            }
        } else {
            await MainActor.run {
                incomingRequesterName = "Someone nearby"
            }
        }
    }

    // MARK: - Deep Link Replay

    private func replayPendingEventIfNeeded(source: String) {
        guard !isConsumingPendingEvent else {
            DebugLog.verbose("[DeepLink] replay blocked source=\(source) reason=alreadyConsuming")
            return
        }

        guard let eventId = deepLinkManager.consumeEventId() else {
            DebugLog.verbose("[DeepLink] no pending event source=\(source)")
            return
        }

        isConsumingPendingEvent = true

        DebugLog.diagnostic("[EventParticipation] user-initiated join via deep link source=\(source) eventId=\(eventId)")

        switchTab(to: .event, source: .user)

        Task {
            await EventJoinService.shared.joinEvent(eventID: eventId)

            await MainActor.run {
                self.isConsumingPendingEvent = false

                if EventJoinService.shared.isEventJoined {
                    switchTab(to: .event, source: .user)
                }

                if EventJoinService.shared.isEventJoined {
                    DebugLog.diagnostic("[EventParticipation] pending event join succeeded eventId=\(eventId)")
                } else {
                    DebugLog.diagnostic("[EventParticipation] pending event join failed eventId=\(eventId)")
                }
            }
        }
    }

    private func switchTab(to target: AppTab, source: TabChangeSource) {
        if source == .user, target == .event {
            EventJoinService.shared.setIntent(.navigateToEvent)
        }
        _ = NavigationState.shared.requestTabChange(
            from: selectedTab,
            to: target,
            source: source,
            sourceName: "MainTabView.userTap",
            binding: &selectedTab
        )
    }
}

private struct MessagesHubView: View {
    private struct ConversationRowModel: Identifiable {
        let id: UUID
        let name: String
        let lastMessageText: String?
        let lastMessageAt: Date?
        let isUnread: Bool
        let conversation: Conversation
    }

    @ObservedObject private var messaging = MessagingService.shared
    @State private var previews: [UUID: MessagingService.ConversationPreview] = [:]
    @State private var participantNames: [UUID: String] = [:]
    @State private var selectedConversation: MessagesDestination?
    @State private var isFetching = false

    private var myId: UUID? { AuthService.shared.currentUser?.id }

    var body: some View {
        Group {
            if messaging.conversations.isEmpty {
                    Text("No messages yet")
                        .foregroundColor(.gray)
                } else {
                    List(conversationRows) { row in
                        Button {
                            let otherId = myId.map { row.conversation.otherParticipant(for: $0) } ?? row.conversation.participantB
                            selectedConversation = MessagesDestination(
                                targetProfileId: otherId,
                                targetName: participantNames[otherId] ?? "Conversation",
                                conversation: row.conversation
                            )
                        } label: {
                            conversationRow(row)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            messaging.setConversationVisibility(conversationId: row.id, isVisible: true)
                        }
                        .onDisappear {
                            messaging.setConversationVisibility(conversationId: row.id, isVisible: false)
                        }
                    }
                    .listStyle(.plain)
                    .tabbedScrollContentClearance(screen: "Messages")
                }
            }
        .task {
            refreshConversations()
        }
        .sheet(item: $selectedConversation) { destination in
            ConversationView(
                targetProfileId: destination.targetProfileId,
                preloadedConversation: destination.conversation,
                preloadedName: destination.targetName
            )
        }
    }

    private var conversationRows: [ConversationRowModel] {
        messaging.conversations
            .map { conversation in
                let preview = previews[conversation.id]
                let content = preview?.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastReadAt = messaging.lastReadAt(for: conversation.id) ?? .distantPast
                let lastMessageAt = preview?.createdAt ?? messaging.lastMessageAt(for: conversation.id)
                return ConversationRowModel(
                    id: conversation.id,
                    name: title(for: conversation),
                    lastMessageText: content,
                    lastMessageAt: lastMessageAt,
                    isUnread: (lastMessageAt ?? .distantPast) > lastReadAt,
                    conversation: conversation
                )
            }
            .sorted {
                ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
            }
    }

    private func conversationRow(_ conversation: ConversationRowModel) -> some View {
        let dateText = conversation.lastMessageAt?.feedRelativeString ?? ""
        let previewText = conversation.lastMessageText?.isEmpty == false
            ? conversation.lastMessageText!
            : "Start a conversation"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.name)
                    .font(.headline.weight(conversation.isUnread ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if conversation.isUnread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
                if !dateText.isEmpty {
                    Text(dateText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(previewText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .opacity(conversation.lastMessageText == nil ? 0.7 : 1.0)
    }

    private func title(for conversation: Conversation) -> String {
        guard let myId else { return "Conversation" }
        let otherId = conversation.otherParticipant(for: myId)
        return participantNames[otherId] ?? "Conversation"
    }

    private func refreshConversations() {
        guard !isFetching else { return }
        isFetching = true

        Task {
            defer { isFetching = false }
            let conversations = await messaging.fetchConversationsSnapshot()
            previews = await messaging.fetchConversationPreviews(conversationIds: conversations.map(\.id))
            await loadParticipantNames(conversations)
        }
    }

    private func loadParticipantNames(_ conversations: [Conversation]) async {
        guard let myId else { return }
        for conversation in conversations {
            let other = conversation.otherParticipant(for: myId)
            if participantNames[other] != nil { continue }

            if let cached = MessagingService.shared.cachedProfileName(for: other) {
                participantNames[other] = cached
                continue
            }

            if let profile = try? await ProfileService.shared.fetchProfileById(other) {
                participantNames[other] = profile.name
                MessagingService.shared.cacheProfileName(profile.name, for: other)
            }
        }
    }
}

private struct MessagesDestination: Identifiable {
    let targetProfileId: UUID
    let targetName: String
    let conversation: Conversation
    var id: UUID { conversation.id }
}
