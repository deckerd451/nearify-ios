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
    @State private var isSavedToContacts = false
    @State private var relationshipMemory: RelationshipMemory?
    @State private var isRelationshipContextExpanded = false

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

                if isSavedToContacts {
                    Label("Saved to Contacts", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.blue.opacity(0.14)))
                }

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

                relationshipContextSection

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

    private var relationshipContextSection: some View {
        let lines = relationshipContextLines()

        return Group {
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Relationship Context")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayedRelationshipContextLines(lines), id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.top, 6)
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if lines.count > 3 {
                            Button(isRelationshipContextExpanded ? "Show less" : "Show more") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isRelationshipContextExpanded.toggle()
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.blue.opacity(0.9))
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
            }
        }
    }

    private func displayedRelationshipContextLines(_ lines: [String]) -> [String] {
        isRelationshipContextExpanded ? lines : Array(lines.prefix(3))
    }

    private func relationshipContextLines() -> [String] {
        guard let memory = relationshipMemory else { return [] }

        var lines: [String] = []

        if let eventName = metAtEventName ?? memory.eventContexts.first {
            lines.append("Met during \(eventName).")
        }

        if !memory.sharedInterests.isEmpty {
            let topics = memory.sharedInterests.prefix(3).joined(separator: ", ")
            lines.append("Shared interests include \(topics).")
        }

        if memory.hasConversation {
            lines.append("You've already exchanged messages.")
        }

        if memory.encounterCount > 1 {
            lines.append("You've crossed paths \(memory.encounterCount) times.")
        }

        if isSavedToContacts {
            lines.append("Saved to Apple Contacts through Nearify.")
        }

        let transformedWhy = transformedRelationshipLine(from: memory.whyLine)
        if let transformedWhy, !transformedWhy.isEmpty {
            lines.append(transformedWhy)
        }

        return Array(NSOrderedSet(array: lines)) as? [String] ?? lines
    }

    private func transformedRelationshipLine(from whyLine: String) -> String? {
        let raw = whyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let blockedPhrases = ["why this matters", "likely to", "recommend", "confidence", "score"]
        let lowered = raw.lowercased()
        if blockedPhrases.contains(where: { lowered.contains($0) }) {
            return nil
        }

        var normalized = raw
            .replacingOccurrences(of: "·", with: ".")
            .replacingOccurrences(of: "worth deepening", with: "a connection you've already built")
            .replacingOccurrences(of: "connection worth building on", with: "a connection you can continue")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalized.hasSuffix(".") {
            normalized += "."
        }

        return normalized.prefix(1).uppercased() + normalized.dropFirst()
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

        // Track whether this profile exists in Saved to Contacts index
        if let savedContact = try? await NearifyContactsIndexService.shared.loadNearifyContacts().first(where: { $0.profileID == profileId }) {
            isSavedToContacts = savedContact.isNearifyEnhanced
        } else {
            isSavedToContacts = false
        }

        relationshipMemory = RelationshipMemoryService.shared.relationships.first(where: { $0.profileId == profileId })

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
