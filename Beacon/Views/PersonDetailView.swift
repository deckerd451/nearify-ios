import SwiftUI

/// Lightweight person detail screen shown when tapping an attendee
struct PersonDetailView: View {
    let attendee: EventAttendee

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingFindSheet = false
    @State private var showContactSaveSheet = false
    @State private var showSavedConfirmation = false
    @State private var publicProfile: PublicProfileSummary?
    @State private var isHeroVisible = false
    @State private var isOpeningConversation = false
    @State private var activeConversation: PersonConversationDestination?
    @State private var contactShareStatus: AttendeeContactActionState = .none

    @ObservedObject private var encounterService = EncounterService.shared

    var body: some View {
        GeometryReader { proxy in
            let layout = layoutMetrics(for: proxy)

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroHeader(layout: layout)
                        contentCards(layout: layout)
                    }
                }
                .ignoresSafeArea(edges: .top)

                floatingTopControls(topInset: proxy.safeAreaInsets.top)

                if showSavedConfirmation {
                    savedConfirmation(bottomInset: proxy.safeAreaInsets.bottom)
                }
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .top)
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
        .sheet(item: $activeConversation) { destination in
            ConversationView(
                targetProfileId: destination.targetProfileId,
                preloadedConversation: destination.conversation,
                preloadedName: destination.targetName
            )
        }
        .task {
            await loadPublicProfile()
            await prefetchContactAvatarIfNeeded()
            await refreshContactShareStatus()
        }
        .onChange(of: ContactShareService.shared.incomingPendingRequest?.id) { _, _ in
            Task { await refreshContactShareStatus() }
        }
        .onChange(of: ContactShareService.shared.outgoingPendingRequests[attendee.id]?.id) { _, _ in
            Task { await refreshContactShareStatus() }
        }
    }

    @ViewBuilder
    private func savedConfirmation(bottomInset: CGFloat) -> some View {
        let eventName = EventJoinService.shared.currentEventName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saveMessage = eventName.flatMap { $0.isEmpty ? nil : $0 }
            .map { "Saved with context from \($0)" } ?? "Saved with Nearify context"

        VStack {
            Spacer()

            Text(saveMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.green))
                .padding(.bottom, max(14, bottomInset + 10))
                .transition(.opacity)
        }
    }

    private func heroHeader(layout: ProfileHeroLayoutMetrics) -> some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground

            VStack(alignment: .leading, spacing: layout.heroStackSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    if let role = attendee.topTags.first {
                        Text(role.uppercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Text(attendee.name)
                        .font(.system(size: layout.nameFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text(contextLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)
                }

                actionButtons(layout: layout)
            }
            .padding(.horizontal, layout.heroHorizontalPadding)
            .padding(.bottom, layout.heroBottomPadding)
        }
        .frame(height: layout.heroHeight)
        .clipped()
        .opacity(isHeroVisible ? 1 : 0)
        .onAppear {
            print("[ProfileHero] layout sizeClass=\(layout.sizeClassLabel) heroHeight=\(Int(layout.heroHeight.rounded()))")
        }
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay(Color.black.opacity(0.3))
                        .overlay(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.78),
                                    Color.black.opacity(0.22),
                                    .clear
                                ],
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
                colors: [
                    Color.indigo,
                    Color.blue.opacity(0.75),
                    Color.teal.opacity(0.7)
                ],
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
                colors: [
                    Color.black.opacity(0.7),
                    .clear
                ],
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
        .padding(.horizontal, 20)
        .padding(.top, max(8, topInset + 8))
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

    private func circularTopButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func actionButtons(layout: ProfileHeroLayoutMetrics) -> some View {
        HStack(spacing: layout.actionSpacing) {
            profileActionButton(
                layout: layout,
                systemImage: "bubble.left.fill",
                title: "Message",
                accessibility: "Message \(attendee.name)"
            ) {
                print("[ProfileHero] message tapped profileId=\(attendee.id)")
                handleMessageTap()
            }

            contactActionButton(layout: layout)

            if showFindAction {
                profileActionButton(
                    layout: layout,
                    systemImage: "location.fill",
                    title: "Find",
                    accessibility: "Find \(attendee.name) nearby"
                ) {
                    print("[ProfileHero] find tapped profileId=\(attendee.id)")
                    showingFindSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func contactActionButton(layout: ProfileHeroLayoutMetrics) -> some View {
        switch contactShareStatus {
        case .accepted:
            profileActionButton(layout: layout, systemImage: "person.crop.circle.badge.plus", title: "Save Contact", accessibility: "Save \(attendee.name) to contacts") {
                guard contactShareStatus == .accepted else {
                    print("[ContactShare] save blocked reason=not-approved source=attendee-card")
                    return
                }
                print("[ContactShare] save unlocked source=attendee-card")
                print("[ProfileHero] save tapped profileId=\(attendee.id)")
                showContactSaveSheet = true
            }
        case .outgoingPending:
            profileActionButton(layout: layout, systemImage: "clock.badge.checkmark", title: "Pending", accessibility: "Pending contact request for \(attendee.name)") {}
                .disabled(true)
                .opacity(0.7)
        case .incomingPending:
            profileActionButton(layout: layout, systemImage: "checkmark.shield", title: "Approve", accessibility: "Approve contact request from \(attendee.name)") {
                if let pending = ContactShareService.shared.incomingPendingRequest,
                   pending.requesterProfileId == attendee.id {
                    Task {
                        await ContactShareService.shared.approve(pending)
                        await refreshContactShareStatus()
                    }
                }
            }
        case .ignoredOrDeclined, .none:
            profileActionButton(layout: layout, systemImage: "person.crop.circle.badge.plus", title: contactShareStatus == .ignoredOrDeclined ? "Request Again" : "Request Contact", accessibility: "Request contact sharing with \(attendee.name)") {
                Task {
                    guard let currentUserId = AuthService.shared.currentUser?.id else { return }
                    let eventId = EventJoinService.shared.currentEventID.flatMap(UUID.init(uuidString:))
                    do {
                        try await ContactShareService.shared.requestContact(
                            requesterProfileId: currentUserId,
                            addresseeProfileId: attendee.id,
                            eventId: eventId
                        )
                        print("[ContactShare] request sent source=attendee-card receiver=\(attendee.id.uuidString)")
                        await refreshContactShareStatus()
                    } catch {
                        print("[ContactShare] request failed source=attendee-card receiver=\(attendee.id.uuidString) error=\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func profileActionButton(
        layout: ProfileHeroLayoutMetrics,
        systemImage: String,
        title: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: layout.actionIconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: layout.actionCircleSize, height: layout.actionCircleSize)
                    .background(.ultraThinMaterial, in: Circle())

                Text(title)
                    .font(layout.actionLabelFont)
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
                    .padding(.top, layout.contentTopPadding + 10)
            }

            if let bio = attendee.bio, !bio.isEmpty {
                sectionCard(title: "Bio") {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: layout.contentMaxWidth)
        .padding(.horizontal, layout.contentHorizontalPadding)
        .padding(.bottom, 28)
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

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
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
        let connectedOnNearify = AttendeeStateResolver.shared.connectedIds.contains(attendee.id)
        let hasConversation = MessagingService.shared.conversations.contains { conversation in
            guard let myId = AuthService.shared.currentUser?.id else { return false }
            return conversation.otherParticipant(for: myId) == attendee.id
        }

        let cues = Array((publicProfile?.earnedTraits.map(\.publicText) ?? []
            + (attendee.skills ?? [])
            + (attendee.interests ?? [])).prefix(2))
        let whyCue = cues.first?.trimmingCharacters(in: .whitespacesAndNewlines)

        let sharedContextItems = Array(((attendee.skills ?? []) + (attendee.interests ?? [])).prefix(3))

        let strongestInteractionLine: String?
        if meaningfulEncounterDuration >= 30 {
            let minutes = max(1, Int(round(Double(meaningfulEncounterDuration) / 60.0)))
            strongestInteractionLine = "\(minutes) min together"
        } else {
            strongestInteractionLine = nil
        }

        let relationshipStatusLine: String?
        if connectedOnNearify && hasConversation {
            relationshipStatusLine = "Already connected and in conversation"
        } else if connectedOnNearify {
            relationshipStatusLine = "Connected on Nearify"
        } else if hasConversation {
            relationshipStatusLine = "Already messaged on Nearify"
        } else {
            relationshipStatusLine = nil
        }

        let followUpLine: String? = {
            if hasConversation, let eventName = EventJoinService.shared.currentEventName?.trimmingCharacters(in: .whitespacesAndNewlines), !eventName.isEmpty {
                return "continue conversation from \(eventName)"
            }

            if let primaryContext = sharedContextItems.first?.trimmingCharacters(in: .whitespacesAndNewlines), !primaryContext.isEmpty {
                return "ask about \(primaryContext.lowercased())"
            }

            if let eventName = EventJoinService.shared.currentEventName?.trimmingCharacters(in: .whitespacesAndNewlines), !eventName.isEmpty {
                return "reconnect at the next \(eventName) event"
            }

            return nil
        }()

        let avatarImageData = ContactAvatarResolver.cachedImageData(avatarUrl: attendee.avatarUrl)
        let sanitizedPhone = sanitizedContactValue(attendee.publicPhone)
        let sanitizedEmail = sanitizedContactValue(attendee.publicEmail)
        let sanitizedLinkedIn = sanitizedContactValue(attendee.linkedInUrl)
        let sanitizedWebsite = sanitizedContactValue(attendee.websiteUrl)

        return ContactDraftData(
            name: attendee.name,
            nearifyProfileIdentifier: attendee.id,
            eventName: EventJoinService.shared.currentEventName,
            imageData: avatarImageData,
            phoneNumbers: attendee.sharePhone == true ? [sanitizedPhone].compactMap { $0 } : [],
            emailAddresses: attendee.shareEmail == true ? [sanitizedEmail].compactMap { $0 } : [],
            linkedInUrl: sanitizedLinkedIn,
            websiteUrl: sanitizedWebsite,
            socialProfiles: [],
            whyThisPersonMatters: whyCue,
            sharedContextItems: sharedContextItems,
            strongestInteractionLine: strongestInteractionLine,
            relationshipStatusLine: relationshipStatusLine,
            timeSpentLine: meaningfulEncounterDuration >= 300 ? "\(max(1, Int(round(Double(meaningfulEncounterDuration) / 60.0)))) min" : nil,
            followUpLine: followUpLine
        )
    }

    private func sanitizedContactValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lowered = trimmed.lowercased()
        let placeholders = ["n/a", "na", "none", "null", "-", "--", "tbd"]
        return placeholders.contains(lowered) ? nil : trimmed
    }

    private func prefetchContactAvatarIfNeeded() async {
        guard let avatarUrl = attendee.avatarUrl,
              ThumbnailCache.shared.thumbnail(for: avatarUrl) == nil else {
            return
        }
        _ = await ThumbnailCache.shared.loadThumbnail(for: avatarUrl)
    }

    private func handleMessageTap() {
        guard !isOpeningConversation else { return }

        isOpeningConversation = true

        Task {
            do {
                _ = try await ConnectionService.shared.createConnectionIfNeeded(to: attendee.id.uuidString)
                print("[MessagingGate] auto-connected target=\(attendee.id.uuidString)")
                let eventId = await MainActor.run {
                    EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) }
                }

                let eventName = await MainActor.run {
                    EventJoinService.shared.currentEventName
                }

                let conversation = try await MessagingService.shared.getOrCreateConversation(
                    with: attendee.id,
                    eventId: eventId,
                    eventName: eventName
                )
                print("[MessagingGate] opening conversation target=\(attendee.id.uuidString)")

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

    private func loadPublicProfile() async {
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

        let generatedProfile = await DynamicProfileService.shared.generatePublicProfile(
            for: attendee.id,
            targetUser: targetUser
        )

        await MainActor.run {
            publicProfile = generatedProfile

            withAnimation(.easeIn(duration: 0.25)) {
                isHeroVisible = true
            }
        }
    }

    private func refreshContactShareStatus() async {
        guard let currentUserId = AuthService.shared.currentUser?.id else { return }

        let incomingForAttendee = ContactShareService.shared.incomingPendingRequest?.requesterProfileId == attendee.id
        let outgoingForAttendee = ContactShareService.shared.outgoingPendingRequests[attendee.id] != nil
        let status = await ContactShareService.shared.statusBetween(currentUserId, attendee.id)

        let resolvedState: AttendeeContactActionState
        switch status {
        case "accepted":
            resolvedState = .accepted
        case "pending" where incomingForAttendee:
            resolvedState = .incomingPending
        case "pending" where outgoingForAttendee:
            resolvedState = .outgoingPending
        case "ignored", "declined":
            resolvedState = .ignoredOrDeclined
        default:
            resolvedState = incomingForAttendee ? .incomingPending : (outgoingForAttendee ? .outgoingPending : .none)
        }

        await MainActor.run {
            contactShareStatus = resolvedState
            print("[AttendeeCard] contact action state=\(resolvedState.rawValue) profile=\(attendee.id.uuidString)")
        }
    }

    private func layoutMetrics(for proxy: GeometryProxy) -> ProfileHeroLayoutMetrics {
        let isCompactWidth = horizontalSizeClass == .compact
        let safeHeight = max(1, proxy.size.height)

        let heroHeight: CGFloat = {
            if isCompactWidth {
                return min(420, max(320, safeHeight * 0.42))
            } else {
                return min(360, max(300, safeHeight * 0.32))
            }
        }()

        return ProfileHeroLayoutMetrics(
            heroHeight: heroHeight,
            heroBottomPadding: isCompactWidth ? 42 : 28,
            heroHorizontalPadding: isCompactWidth ? 24 : 36,
            heroStackSpacing: isCompactWidth ? 14 : 12,
            nameFontSize: isCompactWidth ? 42 : 38,
            actionCircleSize: isCompactWidth ? 68 : 60,
            actionIconSize: isCompactWidth ? 28 : 25,
            actionLabelFont: isCompactWidth ? .footnote.weight(.semibold) : .caption.weight(.semibold),
            actionSpacing: isCompactWidth ? 36 : 28,
            contentTopPadding: isCompactWidth ? 20 : 24,
            contentHorizontalPadding: isCompactWidth ? 20 : 24,
            contentMaxWidth: isCompactWidth ? .infinity : 780,
            sizeClassLabel: isCompactWidth ? "compact" : "regular"
        )
    }
}

private struct ProfileHeroLayoutMetrics {
    let heroHeight: CGFloat
    let heroBottomPadding: CGFloat
    let heroHorizontalPadding: CGFloat
    let heroStackSpacing: CGFloat
    let nameFontSize: CGFloat
    let actionCircleSize: CGFloat
    let actionIconSize: CGFloat
    let actionLabelFont: Font
    let actionSpacing: CGFloat
    let contentTopPadding: CGFloat
    let contentHorizontalPadding: CGFloat
    let contentMaxWidth: CGFloat
    let sizeClassLabel: String
}

private struct PersonConversationDestination: Identifiable {
    let id: UUID
    let targetProfileId: UUID
    let targetName: String
    let conversation: Conversation
}

private enum AttendeeContactActionState: String {
    case none
    case outgoingPending
    case incomingPending
    case accepted
    case ignoredOrDeclined
}
