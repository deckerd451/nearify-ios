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
    @State private var showConversation = false
    @State private var errorMessage: String?
    @State private var showNotConnectedAlert = false

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
        .sheet(isPresented: $showConversation) {
            ConversationView(targetProfileId: profileId)
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

                // Actions
                VStack(spacing: 12) {
                    // Message button
                    Button(action: handleMessageTap) {
                        HStack {
                            Image(systemName: "bubble.left.fill")
                            Text(isConnected ? "Message" : "Connect to message")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isConnected ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
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

        #if DEBUG
        print("[FeedProfile] ✅ Profile loaded: \(profile?.name ?? "nil"), connected: \(isConnected)")
        #endif
    }

    private func handleMessageTap() {
        #if DEBUG
        print("[FeedProfile] 💬 Message tapped for: \(profileId), connected: \(isConnected)")
        #endif

        if isConnected {
            showConversation = true
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
