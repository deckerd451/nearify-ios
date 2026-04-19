import SwiftUI

/// Profile detail screen for viewing another user from the feed.
/// Loads profile data by ID from `profiles` table.
/// Shows avatar, name, bio, skills, interests, and connection/message actions.
struct FeedProfileDetailView: View {
    let profileId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var profile: User?
    @State private var isLoading = true
    @State private var isConnected = false
    @State private var isConnecting = false
    @State private var activeConversation: ConversationDestination?
    @State private var isOpeningConversation = false
    @State private var errorMessage: String?
    @State private var showNotConnectedAlert = false
    @State private var metAtEventName: String?
    @State private var publicProfile: PublicProfileSummary?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.white)
            } else if let profile = profile {
                profileContent(profile)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("Profile not found")
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle(profile?.name ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
        .alert("Can't message yet", isPresented: $showNotConnectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect with this person first to start a conversation.")
        }
        .sheet(item: $activeConversation) { destination in
            ConversationView(
                targetProfileId: destination.targetProfileId,
                preloadedConversation: destination.conversation,
                preloadedName: destination.targetName
            )
        }
    }

    // MARK: - Content

    private func profileContent(_ user: User) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                AvatarView(
                    imageUrl: user.imageUrl,
                    name: user.name,
                    size: 90
                )
                .padding(.top, 24)

                Text(user.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                // "Met at" context — reinforces that connections persist beyond events
                if let eventName = metAtEventName {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("Met at \(eventName)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                if let bio = user.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if let interests = user.interests, !interests.isEmpty {
                    tagSection(title: "Interests", tags: interests, color: .green)
                }

                if let skills = user.skills, !skills.isEmpty {
                    tagSection(title: "Skills", tags: skills, color: .blue)
                }

                // Lately
                if let pub = publicProfile, !pub.latelyLines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lately")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pub.latelyLines, id: \.self) { line in
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }

                // Emerging Strengths
                if let paragraph = publicProfile?.emergingStrengthsParagraph {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Emerging Strengths")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .textCase(.uppercase)

                        Text(paragraph)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }

                // Earned Traits
                if let pub = publicProfile, !pub.earnedTraits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Earned Traits")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pub.earnedTraits) { trait in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Text(trait.publicText)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.85))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }

                // Actions
                VStack(spacing: 12) {
                    // Message button
                    Button(action: handleMessageTap) {
                        HStack {
                            if isOpeningConversation {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "bubble.left.fill")
                            }
                            Text(isConnected ? "Message" : "Connect to message")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isConnected ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isOpeningConversation)
                    .buttonStyle(.plain)

                    // Connect button (if not connected)
                    if !isConnected {
                        Button(action: handleConnect) {
                            HStack {
                                if isConnecting {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "person.badge.plus")
                                    Text("Connect")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isConnecting)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)

                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Tag Section

    private func tagSection(title: String, tags: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
                .textCase(.uppercase)

            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .foregroundColor(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(color.opacity(0.12))
                        .cornerRadius(12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
    }

    // MARK: - Actions

    private func loadProfile() async {
        isLoading = true
        defer { isLoading = false }

        #if DEBUG
        print("[FeedProfile] 🔍 Loading profile: \(profileId)")
        #endif

        profile = try? await ProfileService.shared.fetchProfileById(profileId)
        isConnected = await ConnectionService.shared.isConnected(with: profileId)

        // Resolve "Met at [Event]" context via MessagingService
        metAtEventName = await MessagingService.shared.eventName(forConversationWith: profileId)

        // Generate public-facing dynamic profile sections
        publicProfile = await DynamicProfileService.shared.generatePublicProfile(
            for: profileId,
            targetUser: profile
        )

        #if DEBUG
        print("[FeedProfile] ✅ Profile loaded: \(profile?.name ?? "nil"), connected: \(isConnected), metAt: \(metAtEventName ?? "nil")")
        #endif
    }

    private func handleMessageTap() {
        #if DEBUG
        print("[FeedProfile] 💬 Message tapped for: \(profileId), connected: \(isConnected)")
        #endif

        guard !isOpeningConversation else { return }

        if isConnected {
            isOpeningConversation = true
            Task {
                // Prefer the event where we originally met this person (from connection
                // or encounter), falling back to the current event if we're in one.
                // This ensures "Met at [Event]" context appears even after the event ends.
                var eventId: UUID?
                var eventName: String?

                // Check connection for event context
                if let connections = try? await ConnectionService.shared.fetchConnections() {
                    let myId = AuthService.shared.currentUser?.id
                    if let conn = connections.first(where: {
                        let other = $0.otherUser(for: myId ?? UUID())
                        return other.id == profileId
                    }) {
                        eventId = conn.eventId
                        // eventName not stored on connection — will come from conversation
                    }
                }

                // Fall back to current event context
                if eventId == nil {
                    eventId = await MainActor.run { EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) } }
                    eventName = await MainActor.run { EventJoinService.shared.currentEventName }
                }

                do {
                    let convo = try await MessagingService.shared.getOrCreateConversation(
                        with: profileId,
                        eventId: eventId,
                        eventName: eventName
                    )
                    await MessagingService.shared.fetchMessages(conversationId: convo.id)

                    await MainActor.run {
                        activeConversation = ConversationDestination(
                            id: convo.id,
                            targetProfileId: profileId,
                            targetName: profile?.name ?? "...",
                            conversation: convo
                        )
                        isOpeningConversation = false
                        print("[FeedProfile] ✅ Presenting conversation \(convo.id)")
                    }
                } catch {
                    await MainActor.run {
                        isOpeningConversation = false
                        print("[FeedProfile] ❌ Conversation open failed: \(error)")
                    }
                }
            }
        } else {
            showNotConnectedAlert = true
        }
    }

    private func handleConnect() {
        #if DEBUG
        print("[FeedProfile] 🤝 Connect tapped for: \(profileId)")
        #endif

        isConnecting = true
        Task {
            do {
                let result = try await ConnectionService.shared.createConnectionIfNeeded(to: profileId.uuidString)
                await MainActor.run {
                    isConnecting = false
                    if result == .created || result == .alreadyExists {
                        isConnected = true
                    }
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = error.localizedDescription
                }
                print("[FeedProfile] ❌ Connect failed: \(error)")
            }
        }
    }
}
