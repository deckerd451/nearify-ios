import SwiftUI

// MARK: - Feed Route

/// Typed navigation destinations for feed card actions.
enum FeedRoute: Hashable {
    case profileDetail(profileId: UUID)
}

/// Social Memory Feed — the primary experience.
struct FeedView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared

    @State private var selectedFilter: FeedItemType? = nil
    @State private var conversationTargetId: UUID?
    @State private var showConversation = false
    @State private var showNotConnectedAlert = false
    @State private var isConnecting = false
    @State private var navigationPath = NavigationPath()

    private var displayItems: [FeedItem] {
        feedService.filteredItems(by: selectedFilter)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                if feedService.isLoading && feedService.feedItems.isEmpty {
                    loadingState
                } else if feedService.feedItems.isEmpty {
                    emptyState
                } else {
                    feedContent
                }
            }
            .navigationTitle("Your Feed")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: FeedRoute.self) { route in
                switch route {
                case .profileDetail(let profileId):
                    FeedProfileDetailView(profileId: profileId)
                }
            }
            .refreshable {
                await refreshFeed()
            }
            .onAppear {
                Task { await refreshFeed() }
            }
            .sheet(isPresented: $showConversation) {
                if let targetId = conversationTargetId {
                    ConversationView(targetProfileId: targetId)
                }
            }
            .alert("Can't message yet", isPresented: $showNotConnectedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Connect with this person first to start a conversation.")
            }
        }
    }

    // MARK: - Feed Content

    private var feedContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                filterPills
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                LazyVStack(spacing: 12) {
                    ForEach(displayItems) { item in
                        feedCard(for: item)
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Filter Pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("All", isSelected: selectedFilter == nil) {
                    selectedFilter = nil
                }
                filterPill("Connections", isSelected: selectedFilter == .connection) {
                    selectedFilter = .connection
                }
                filterPill("Encounters", isSelected: selectedFilter == .encounter) {
                    selectedFilter = .encounter
                }
                filterPill("Messages", isSelected: selectedFilter == .message) {
                    selectedFilter = .message
                }
                filterPill("Follow-ups", isSelected: selectedFilter == .suggestion) {
                    selectedFilter = .suggestion
                }
            }
        }
    }

    private func filterPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(isSelected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white : Color.white.opacity(0.1))
            )
            .contentShape(Capsule())
            .onTapGesture { action() }
    }

    // MARK: - Card Router

    @ViewBuilder
    private func feedCard(for item: FeedItem) -> some View {
        let profileId = item.actorProfileId

        switch item.feedType {
        case .connection:
            ConnectionCardView(
                item: item,
                onMessage: { handleMessage(profileId: profileId, source: "connection") },
                onViewProfile: { handleViewProfile(profileId: profileId, source: "connection") }
            )
        case .encounter:
            EncounterCardView(
                item: item,
                onViewProfile: { handleViewProfile(profileId: profileId, source: "encounter") },
                onConnect: { handleConnect(profileId: profileId, source: "encounter") },
                onDismiss: { handleDismiss(item: item) }
            )
        case .suggestion:
            SuggestionCardView(
                item: item,
                onConnect: { handleConnect(profileId: profileId, source: "suggestion") },
                onMessage: { handleMessage(profileId: profileId, source: "suggestion") }
            )
        case .message:
            MessageCardView(
                item: item,
                onReply: { handleMessage(profileId: profileId, source: "message") }
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.wave.2")
                .font(.system(size: 56))
                .foregroundColor(.gray.opacity(0.5))

            VStack(spacing: 8) {
                Text("Join an event to start building your network")
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("Your connections, encounters, and messages will appear here")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Text("Scan to join event")
                .fontWeight(.semibold)
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white))
                .contentShape(Capsule())
                .onTapGesture { selectedTab = .scan }

            Spacer()
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Loading your feed…")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }

    // MARK: - Action Handlers

    private func handleViewProfile(profileId: UUID?, source: String) {
        guard let id = profileId else {
            print("[FeedAction] ⚠️ View Profile tapped from \(source) but profileId is nil")
            return
        }

        print("[FeedAction] 👤 View Profile tapped for profile \(id) (source: \(source))")
        navigationPath.append(FeedRoute.profileDetail(profileId: id))
        print("[FeedAction] 📍 Navigation path appended, count: \(navigationPath.count)")
    }

    private func handleMessage(profileId: UUID?, source: String) {
        guard let id = profileId else {
            print("[FeedAction] ⚠️ Message tapped from \(source) but profileId is nil")
            return
        }

        print("[FeedAction] 💬 Message tapped for profile \(id) (source: \(source))")
        print("[FeedAction] 🔍 Checking connection eligibility...")

        Task {
            let connected = await ConnectionService.shared.isConnected(with: id)
            print("[FeedAction] 🔗 isConnected result for \(id): \(connected)")

            await MainActor.run {
                if connected {
                    print("[FeedAction] ✅ Opening conversation with \(id)")
                    conversationTargetId = id
                    showConversation = true
                } else {
                    print("[FeedAction] ⛔ Not connected with \(id), showing alert")
                    showNotConnectedAlert = true
                }
            }
        }
    }

    private func handleConnect(profileId: UUID?, source: String) {
        guard let id = profileId else {
            print("[FeedAction] ⚠️ Connect tapped from \(source) but profileId is nil")
            return
        }
        guard !isConnecting else {
            print("[FeedAction] ⏳ Connect already in progress, ignoring")
            return
        }

        print("[FeedAction] 🤝 Connect tapped for profile \(id) (source: \(source))")

        isConnecting = true
        Task {
            do {
                let result = try await ConnectionService.shared.createConnectionIfNeeded(to: id.uuidString)
                print("[FeedAction] ✅ Connect result for \(id): \(result)")
                await refreshFeed()
            } catch {
                print("[FeedAction] ❌ Connect failed for \(id): \(error)")
            }
            await MainActor.run { isConnecting = false }
        }
    }

    private func handleDismiss(item: FeedItem) {
        print("[FeedAction] 🗑️ Dismiss tapped for feed item \(item.id)")
        // TODO: Delete feed item from DB and remove from local list
    }

    private func refreshFeed() async {
        await feedService.generateConnectionFeedItems()
        await feedService.generateEncounterFeedItems()
        await feedService.generateMessageFeedItems()
        feedService.refresh()
        #if DEBUG
        print("[Feed] 🔄 Feed refresh complete (connections + encounters + messages)")
        #endif
    }
}
