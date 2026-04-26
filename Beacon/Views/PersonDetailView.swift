import SwiftUI

/// Lightweight person detail screen shown when tapping an attendee
struct PersonDetailView: View {
    let attendee: EventAttendee

    @Environment(\.dismiss) private var dismiss

    @State private var showingFindSheet = false
    @State private var showContactSaveSheet = false
    @State private var showSavedConfirmation = false
    @State private var publicProfile: PublicProfileSummary?
    @State private var isHeroVisible = false
    @State private var isOpeningConversation = false
    @State private var activeConversation: PersonConversationDestination?

    @ObservedObject private var encounterService = EncounterService.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = layoutMetrics(for: proxy)

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroHeader(layout: layout)

                        actionButtons(layout: layout)
                            .padding(.top, 12)
                            .padding(.bottom, 24)

                        contentCards(layout: layout)
                    }
                }
                .ignoresSafeArea(edges: .top)

                floatingTopControls(topInset: proxy.safeAreaInsets.top)

                if showSavedConfirmation {
                    VStack {
                        Spacer()
                        Text("Saved to your contacts with context from Nearify")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.green))
                            .padding(.bottom, 14)
                            .transition(.opacity)
                    }
                }
            }
            .background(Color.black)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFindSheet) {
            FindAttendeeView(attendee: attendee)
        }
        .sheet(isPresented: $showContactSaveSheet) {
            ContactSaveSheet(draft: contactDraft) { didSave in
                showContactSaveSheet = false
                guard didSave else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSavedConfirmation = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSavedConfirmation = false
                    }
                }
            }
        }
        .sheet(item: $activeConversation) { (destination: PersonConversationDestination) in
            ConversationView(
                targetProfileId: destination.targetProfileId,
                preloadedConversation: destination.conversation,
                preloadedName: destination.targetName
            )
        }
        .task {
            print("[ProfileHero] rendered for profileId=\(attendee.id)")

            let targetUser = User(
                id: attendee.id,
                userId: nil,
                name: attendee.name,
                email: nil,
                bio: attendee.bio,
                skills: attendee.skills,
                interests: attendee.interests,
                imageUrl: attendee.avatarUrl,
                imagePath: nil,
                profileCompleted: nil,
                connectionCount: nil,
                createdAt: nil,
                updatedAt: nil
            )
            publicProfile = await DynamicProfileService.shared.generatePublicProfile(
                for: attendee.id,
                targetUser: targetUser
            )

            withAnimation(.easeIn(duration: 0.25)) {
                isHeroVisible = true
            }
        }
    }

    private func layoutMetrics(for proxy: GeometryProxy) -> ProfileHeroLayoutMetrics {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let width = proxy.size.width

        return ProfileHeroLayoutMetrics(
            heroHeight: isPad ? 330 : 376,
            actionButtonSize: isPad ? 68 : 66,
            cardMaxWidth: isPad ? min(width - 40, 780) : .infinity,
            horizontalPadding: isPad ? 24 : 20
        )
    }

    private func heroHeader(layout: ProfileHeroLayoutMetrics) -> some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if let role = attendee.topTags.first {
                        Text(role.uppercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Text(attendee.name)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text(contextLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, layout.horizontalPadding + 4)
            .padding(.bottom, 26)
        }
        .frame(height: layout.heroHeight)
        .clipped()
        .opacity(isHeroVisible ? 1 : 0)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let imageUrl = attendee.avatarUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    fallbackHeroBackground
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .overlay(Color.black.opacity(0.28))
                        .overlay(
                            LinearGradient(
                                colors: [Color.black.opacity(0.72), Color.black.opacity(0.15), .clear],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .clipped()
                case .failure:
                    fallbackHeroBackground
                @unknown default:
                    fallbackHeroBackground
                }
            }
        } else {
            fallbackHeroBackground
        }
    }

    private var fallbackHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo, Color.blue.opacity(0.75), Color.teal.opacity(0.7)],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )

            Text(attendee.initials)
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
        }
        .overlay(Color.black.opacity(0.25))
        .overlay(
            LinearGradient(
                colors: [Color.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    private func floatingTopControls(topInset: CGFloat) -> some View {
        HStack {
            backButton()

            Spacer()

            editButton()
        }
        .padding(.top, topInset + 12)
        .padding(.horizontal, 16)
    }

    private func backButton() -> some View {
        circularTopButton(systemImage: "chevron.left", label: "Back") {
            dismiss()
        }
    }

    @ViewBuilder
    private func editButton() -> some View {
        if attendee.id == AuthService.shared.currentUser?.id {
            circularTopButton(systemImage: "square.and.pencil", label: "Edit profile") {
                // Keep existing screen behavior: no-op for now
            }
        }
    }

    private func circularTopButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .accessibilityLabel(label)
    }

    private func actionButtons(layout: ProfileHeroLayoutMetrics) -> some View {
        HStack(spacing: 22) {
            profileActionButton(systemImage: "bubble.left.fill", title: "Message", accessibility: "Message \(attendee.name)", buttonSize: layout.actionButtonSize) {
                print("[ProfileHero] message tapped profileId=\(attendee.id)")
                handleMessageTap()
            }

            profileActionButton(systemImage: "person.crop.circle.badge.plus", title: "Save", accessibility: "Save \(attendee.name) to contacts", buttonSize: layout.actionButtonSize) {
                print("[ProfileHero] save tapped profileId=\(attendee.id)")
                showContactSaveSheet = true
            }

            if showFindAction {
                profileActionButton(systemImage: "location.fill", title: "Find", accessibility: "Find \(attendee.name) nearby", buttonSize: layout.actionButtonSize) {
                    print("[ProfileHero] find tapped profileId=\(attendee.id)")
                    showingFindSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
    }

    private func profileActionButton(systemImage: String, title: String, accessibility: String, buttonSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.ultraThinMaterial, in: Circle())

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func contentCards(layout: ProfileHeroLayoutMetrics) -> some View {
        VStack(spacing: 18) {
            if !topEarnedTraits.isEmpty {
                earnedTraitsHighlight
                    .padding(.top, 20)
            }

            if let bio = attendee.bio, !bio.isEmpty {
                sectionCard(title: "Bio") {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }

            if let skills = attendee.skills, !skills.isEmpty {
                sectionCard(title: "Skills") {
                    tagSection(tags: skills, color: .blue)
                }
            }

            if let interests = attendee.interests, !interests.isEmpty {
                sectionCard(title: "Interests") {
                    tagSection(tags: interests, color: .green)
                }
            }

            if let pub = publicProfile, !pub.latelyLines.isEmpty {
                sectionCard(title: "Lately") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pub.latelyLines, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            if let paragraph = publicProfile?.emergingStrengthsParagraph {
                sectionCard(title: "Emerging Strengths") {
                    Text(paragraph)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            statusRow

            Spacer(minLength: 40)
        }
        .frame(maxWidth: layout.cardMaxWidth)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var earnedTraitsHighlight: some View {
        sectionCard(title: "Earned Traits") {
            Text(topEarnedTraits.map(\.publicText).joined(separator: " · "))
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(attendee.isActiveNow ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(attendee.lastSeenText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func tagSection(tags: [String], color: Color) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color.opacity(0.12))
                    )
                    .foregroundColor(color)
            }
        }
    }

    private var meaningfulEncounterDuration: Int {
        encounterService.activeEncounters[attendee.id]?.totalSeconds ?? 0
    }

    private var contextLine: String {
        if let eventName = EventJoinService.shared.currentEventName {
            return "Met at \(eventName)"
        }

        if meaningfulEncounterDuration >= 120 {
            return "You spent meaningful time together"
        }

        return "Connected via Nearify"
    }

    private var topEarnedTraits: [EarnedTrait] {
        Array((publicProfile?.earnedTraits ?? []).prefix(3))
    }

    private var showFindAction: Bool {
        attendee.isActiveNow
    }

    private var contactDraft: ContactDraftData {
        ContactDraftData(
            name: attendee.name,
            eventName: EventJoinService.shared.currentEventName ?? "Nearify event",
            interests: attendee.interests ?? [],
            skills: attendee.skills ?? [],
            earnedTraits: publicProfile?.earnedTraits.map(\.publicText) ?? []
        )
    }

    private func handleMessageTap() {
        guard !isOpeningConversation else { return }

        isOpeningConversation = true

        Task {
            do {
                let eventId = await MainActor.run {
                    EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) }
                }
                let eventName = await MainActor.run { EventJoinService.shared.currentEventName }

                let conversation = try await MessagingService.shared.getOrCreateConversation(
                    with: attendee.id,
                    eventId: eventId,
                    eventName: eventName
                )
                await MessagingService.shared.fetchMessages(conversationId: conversation.id)

                await MainActor.run {
                    activeConversation = PersonConversationDestination(
                        id: conversation.id,
                        targetProfileId: attendee.id,
                        targetName: attendee.name,
                        conversation: conversation
                    )
                    isOpeningConversation = false
                }
            } catch {
                await MainActor.run {
                    isOpeningConversation = false
                    print("[ProfileHero] message open failed profileId=\(attendee.id) error=\(error.localizedDescription)")
                }
            }
        }
    }
}

private struct ProfileHeroLayoutMetrics {
    let heroHeight: CGFloat
    let actionButtonSize: CGFloat
    let cardMaxWidth: CGFloat
    let horizontalPadding: CGFloat
}

private struct PersonConversationDestination: Identifiable {
    let id: UUID
    let targetProfileId: UUID
    let targetName: String
    let conversation: Conversation
}
