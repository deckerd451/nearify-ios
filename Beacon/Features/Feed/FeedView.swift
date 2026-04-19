import SwiftUI

// MARK: - Feed Route

/// Typed navigation destinations for feed card actions.
enum FeedRoute: Hashable {
    case profileDetail(profileId: UUID)
}

// MARK: - Conversation Destination

/// Single source of truth for conversation presentation.
/// Only created after async resolution completes — never blank.
struct ConversationDestination: Identifiable {
    let id: UUID  // conversation ID
    let targetProfileId: UUID
    let targetName: String
    let conversation: Conversation
}

/// Social Memory Feed — the primary experience.
struct FeedView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared

    @State private var selectedFilter: FeedItemType? = nil
    @State private var activeConversation: ConversationDestination?
    @State private var showNotConnectedAlert = false
    @State private var isOpeningConversation = false
    @State private var isConnecting = false
    @State private var navigationPath = NavigationPath()
    @State private var showScanner = false

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

                // Loading overlay while resolving conversation
                if isOpeningConversation {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                        Text("Opening conversation…")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
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
                await feedService.generateConnectionFeedItems()
                await feedService.generateEncounterFeedItems()
                await feedService.generateMessageFeedItems()
                feedService.refresh()
            }
            .onAppear {
                feedService.requestRefresh(reason: "feed-appear")
            }
            .sheet(item: $activeConversation) { destination in
                ConversationView(
                    targetProfileId: destination.targetProfileId,
                    preloadedConversation: destination.conversation,
                    preloadedName: destination.targetName
                )
            }
            .alert("Can't message yet", isPresented: $showNotConnectedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Connect with this person first to start a conversation.")
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(
                    selectedTab: $selectedTab,
                    onSuccess: { _ in showScanner = false },
                    onCancel: { showScanner = false }
                )
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
                .onTapGesture { showScanner = true }

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
    }

    private func handleMessage(profileId: UUID?, source: String) {
        guard let id = profileId else {
            print("[FeedAction] ⚠️ Message tapped from \(source) but profileId is nil")
            return
        }

        // Prevent double-taps while resolving
        guard !isOpeningConversation else {
            print("[FeedAction] ⏳ Already opening conversation, ignoring tap")
            return
        }

        print("[FeedAction] 💬 Message tapped for profile \(id) (source: \(source))")

        isOpeningConversation = true

        Task {
            print("[FeedAction] 🔍 Resolving conversation start for \(id)...")

            // Step 1: Check connection
            let connected = await ConnectionService.shared.isConnected(with: id)
            print("[FeedAction] 🔗 isConnected result for \(id): \(connected)")

            guard connected else {
                await MainActor.run {
                    isOpeningConversation = false
                    showNotConnectedAlert = true
                    print("[FeedAction] ⛔ Not connected with \(id), showing alert")
                }
                return
            }

            // Step 2: Resolve profile name
            var targetName = "..."
            if let profile = try? await ProfileService.shared.fetchProfileById(id) {
                targetName = profile.name
            }
            print("[FeedAction] 👤 Profile resolved: \(targetName)")

            // Step 3: Get or create conversation
            let eventId = await MainActor.run { EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) } }
            let eventName = await MainActor.run { EventJoinService.shared.currentEventName }

            do {
                let convo = try await MessagingService.shared.getOrCreateConversation(
                    with: id,
                    eventId: eventId,
                    eventName: eventName
                )
                print("[FeedAction] 💬 Conversation resolved: \(convo.id)")

                // Step 4: Pre-load messages
                await MessagingService.shared.fetchMessages(conversationId: convo.id)
                print("[FeedAction] 📨 Initial messages loaded")

                // Step 5: NOW present — everything is ready
                await MainActor.run {
                    activeConversation = ConversationDestination(
                        id: convo.id,
                        targetProfileId: id,
                        targetName: targetName,
                        conversation: convo
                    )
                    isOpeningConversation = false
                    print("[FeedAction] ✅ Presenting conversation with \(targetName) (\(id))")
                }
            } catch {
                await MainActor.run {
                    isOpeningConversation = false
                    if case MessagingError.notConnected = error {
                        showNotConnectedAlert = true
                    }
                    print("[FeedAction] ❌ Conversation open failed: \(error)")
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
                feedService.requestRefresh(reason: "connection-created")
            } catch {
                print("[FeedAction] ❌ Connect failed for \(id): \(error)")
            }
            await MainActor.run { isConnecting = false }
        }
    }

    private func handleDismiss(item: FeedItem) {
        print("[FeedAction] 🗑️ Dismiss tapped for feed item \(item.id)")
    }
}
