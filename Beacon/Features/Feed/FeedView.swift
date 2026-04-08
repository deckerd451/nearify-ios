import SwiftUI

/// Social Memory Feed — the primary experience.
/// System-generated timeline of encounters, connections, messages, and follow-ups.
/// This is NOT a social media feed. It is memory + intelligence + real-world interaction capture.
struct FeedView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    
    @State private var selectedFilter: FeedItemType? = nil
    @State private var selectedConversationTarget: UUID?
    @State private var showConversation = false
    
    private var displayItems: [FeedItem] {
        feedService.filteredItems(by: selectedFilter)
    }
    
    var body: some View {
        NavigationStack {
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
            .refreshable {
                await refreshFeed()
            }
            .onAppear {
                Task {
                    await refreshFeed()
                }
            }
            .sheet(isPresented: $showConversation) {
                if let targetId = selectedConversationTarget {
                    ConversationView(targetProfileId: targetId)
                }
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
        Button(action: action) {
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
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Card Router
    
    @ViewBuilder
    private func feedCard(for item: FeedItem) -> some View {
        switch item.feedType {
        case .connection:
            ConnectionCardView(
                item: item,
                onMessage: { openConversation(with: item.actorProfileId) },
                onViewProfile: { /* TODO: navigate to profile */ }
            )
        case .encounter:
            EncounterCardView(
                item: item,
                onConnect: { /* TODO: create connection */ },
                onDismiss: { /* TODO: dismiss feed item */ }
            )
        case .suggestion:
            SuggestionCardView(
                item: item,
                onConnect: { /* TODO: create connection */ },
                onMessage: { openConversation(with: item.actorProfileId) }
            )
        case .message:
            MessageCardView(
                item: item,
                onReply: { openConversation(with: item.actorProfileId) }
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
            
            Button(action: { selectedTab = .scan }) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan to join event")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            
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
    
    // MARK: - Helpers
    
    private func openConversation(with profileId: UUID?) {
        guard let id = profileId else { return }
        selectedConversationTarget = id
        showConversation = true
    }
    
    private func refreshFeed() async {
        await feedService.generateConnectionFeedItems()
        await feedService.generateEncounterFeedItems()
        feedService.refresh()
    }
}
