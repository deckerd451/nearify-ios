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

struct MainTabView: View {
    let currentUser: User
    @Binding var selectedTab: AppTab

    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @State private var isConsumingPendingEvent = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppTab.home)

            NavigationStack {
                PeopleView()
            }
            .tabItem {
                Label("People", systemImage: "person.2.fill")
            }
            .tag(AppTab.people)

            ExploreView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Explore", systemImage: "safari")
                }
                .tag(AppTab.event)

            MyQRView(currentUser: currentUser)
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
                .tag(AppTab.profile)

            MessagesHubView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(AppTab.messages)
        }
        .onAppear {
            #if DEBUG
            print("🚨 MainTabView appeared")
            #endif
            replayPendingEventIfNeeded(source: "onAppear")
        }
        .onReceive(deepLinkManager.$pendingEventId.removeDuplicates()) { pendingEventId in
            guard pendingEventId != nil else { return }
            #if DEBUG
            print("[DeepLink] 🟡 pendingEventId changed while MainTabView active: \(pendingEventId ?? "nil")")
            #endif
            replayPendingEventIfNeeded(source: "onReceive")
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            MessagingRefreshCoordinator.shared.requestRefresh(reason: .tabChange)
            #if DEBUG
            print("[TAB-WRITE] \(oldValue) → \(newValue)")
            #endif
        }
    }

    // MARK: - Deep Link Replay

    private func replayPendingEventIfNeeded(source: String) {
        guard !isConsumingPendingEvent else {
            #if DEBUG
            print("[DeepLink] ⛔ Replay blocked (\(source)) — already consuming pending event")
            #endif
            return
        }

        guard let eventId = deepLinkManager.consumeEventId() else {
            #if DEBUG
            print("[DeepLink] 📭 No pending event to replay (\(source))")
            #endif
            return
        }

        isConsumingPendingEvent = true

        #if DEBUG
        print("[EventJoin] ✅ User-initiated join via deep link (source: \(source), eventId: \(eventId))")
        #endif

        switchTab(to: .event, source: .user)

        Task {
            await EventJoinService.shared.joinEvent(eventID: eventId)

            await MainActor.run {
                self.isConsumingPendingEvent = false

                if EventJoinService.shared.isEventJoined {
                    switchTab(to: .event, source: .user)
                }

                #if DEBUG
                if EventJoinService.shared.isEventJoined {
                    print("[DeepLink] ✅ Pending event join succeeded: \(eventId)")
                } else {
                    print("[DeepLink] ❌ Pending event join failed: \(eventId)")
                }
                #endif
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
            binding: &selectedTab
        )
    }
}

private struct MessagesHubView: View {
    @ObservedObject private var messaging = MessagingService.shared
    @State private var previews: [UUID: MessagingService.ConversationPreview] = [:]
    @State private var participantNames: [UUID: String] = [:]
    @State private var selectedConversation: MessagesDestination?

    private var myId: UUID? { AuthService.shared.currentUser?.id }

    var body: some View {
        NavigationStack {
            Group {
                if messaging.conversations.isEmpty {
                    Text("No messages yet")
                        .foregroundColor(.gray)
                } else {
                    List(messaging.conversations) { conversation in
                        Button {
                            let otherId = myId.map { conversation.otherParticipant(for: $0) } ?? conversation.participantB
                            selectedConversation = MessagesDestination(
                                targetProfileId: otherId,
                                targetName: participantNames[otherId] ?? "Conversation",
                                conversation: conversation
                            )
                        } label: {
                            conversationRow(conversation)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Messages")
        }
        .task {
            await refresh()
        }
        .sheet(item: $selectedConversation) { destination in
            ConversationView(
                targetProfileId: destination.targetProfileId,
                preloadedConversation: destination.conversation,
                preloadedName: destination.targetName
            )
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        let preview = previews[conversation.id]
        let dateText = preview?.createdAt?.feedRelativeString ?? ""
        let content = preview?.content ?? "Start a conversation"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title(for: conversation))
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if !dateText.isEmpty {
                    Text(dateText)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func title(for conversation: Conversation) -> String {
        guard let myId else { return "Conversation" }
        let otherId = conversation.otherParticipant(for: myId)
        return participantNames[otherId] ?? "Conversation"
    }

    private func refresh() async {
        let conversations = await messaging.fetchConversationsSnapshot()
        previews = await messaging.fetchConversationPreviews(conversationIds: conversations.map(\.id))
        await loadParticipantNames(conversations)
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
