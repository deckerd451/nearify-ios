import SwiftUI

/// Dual-layer person intelligence surface.
/// Surface layer: fast, calm, actionable cards.
/// Deep layer: expandable structured reasoning per person.
struct PeopleView: View {
    @ObservedObject private var memory = RelationshipMemoryService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var targetIntent = TargetIntentManager.shared
    @ObservedObject private var navigationState = NavigationState.shared
    @ObservedObject private var controller = PeopleIntelligenceController.shared

    @State private var expandedPersonId: UUID?
    @State private var activeConversation: PeopleConversationTarget?
    @State private var profileSheetTarget: ProfileSheetTarget?
    @State private var findTarget: EventAttendee?
    @State private var isOpeningConversation = false
    @State private var highlightedProfileId: UUID?

    /// Sections are read from the controller, which handles debouncing
    /// and change detection. No direct computation in the view.
    private var sections: PeopleIntelligenceBuilder.Sections {
        controller.sections
    }

    private var isEmpty: Bool {
        sections.hereNow.isEmpty && sections.followUp.isEmpty && sections.notHere.isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if memory.isLoading && memory.relationships.isEmpty && attendeesService.attendees.isEmpty {
                ScrollView { loadingState.frame(maxWidth: .infinity) }
            } else if isEmpty {
                ScrollView { emptyState.frame(maxWidth: .infinity) }
            } else {
                sectionedList
            }

            if isOpeningConversation {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(.white).scaleEffect(1.2)
                    Text("Opening conversation…")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            memory.requestRefresh(reason: "people-pull")
            PeopleRefreshCoordinator.shared.requestRefresh(reason: "people-pull")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        .onAppear {
            memory.requestRefresh(reason: "people-appear")
            PeopleRefreshCoordinator.shared.requestRefresh(reason: "people-appear")
        }
        .onChange(of: eventJoin.isEventJoined) { _, isJoined in
            // Clear event context when user leaves the event
            if !isJoined && navigationState.eventContext != nil {
                navigationState.eventContext = nil
            }
        }
        .sheet(item: $activeConversation) { target in
            ConversationView(
                targetProfileId: target.profileId,
                preloadedConversation: target.conversation,
                preloadedName: target.name
            )
        }
        .sheet(item: $profileSheetTarget) { target in
            NavigationStack { FeedProfileDetailView(profileId: target.profileId) }
        }
        .sheet(item: $findTarget) { attendee in
            FindAttendeeView(attendee: attendee)
                .onAppear {
                    #if DEBUG
                    print("[FindFlow] Presented for \(attendee.name)")
                    #endif
                }
                .onDisappear {
                    #if DEBUG
                    print("[FindFlow] Dismissed for \(attendee.name)")
                    #endif
                }
        }
    }

    // MARK: - Sectioned List

    private var sectionedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.sectionSpacing) {
                    // Event context banner — shown when navigated from Home
                    if let ctx = navigationState.eventContext {
                        eventContextBanner(ctx)
                    }

                    if !sections.hereNow.isEmpty {
                        sectionBlock(
                            title: "Here Now", icon: "circle.fill",
                            color: .green, subtitle: "Active at this event right now",
                            people: sections.hereNow
                        )
                    }

                    if !sections.followUp.isEmpty {
                        sectionBlock(
                            title: "Follow Up", icon: "exclamationmark.bubble",
                            color: .yellow, subtitle: "You spent meaningful time together",
                            people: sections.followUp
                        )
                    }

                    if !sections.notHere.isEmpty {
                        sectionBlock(
                            title: "Past / Other", icon: "sparkles",
                            color: .white.opacity(0.6), subtitle: "People you've interacted with",
                            people: sections.notHere
                        )
                    }
                }
                .padding(.top, DesignTokens.titleToContent)
                .padding(.bottom, DesignTokens.sectionSpacing)
            }
            .onChange(of: navigationState.peopleFocusTarget) { _, target in
                guard let target = target else { return }
                expandedPersonId = target.profileId
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(target.profileId, anchor: .center)
                    highlightedProfileId = target.profileId
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        highlightedProfileId = nil
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    navigationState.peopleFocusTarget = nil
                }
            }
        }
    }

    // MARK: - Section Block

    private func sectionBlock(
        title: String, icon: String, color: Color,
        subtitle: String, people: [PersonIntelligence]
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.elementSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption).foregroundColor(color)
                    Text(title.uppercased())
                        .font(.caption).fontWeight(.bold).foregroundColor(color).tracking(1.0)
                    Spacer()
                    Text("\(people.count)").font(.caption2).foregroundColor(.gray)
                }
                Text(subtitle).font(.system(size: 11)).foregroundColor(.gray.opacity(0.6))
            }
            .padding(.horizontal)

            ForEach(people) { person in
                personCard(person, sectionColor: color)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Person Card (Surface + Deep)

    private func personCard(_ person: PersonIntelligence, sectionColor: Color) -> some View {
        let isExpanded = expandedPersonId == person.id

        return VStack(alignment: .leading, spacing: 0) {
            // ── Surface Layer ──
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedPersonId = isExpanded ? nil : person.id
                    #if DEBUG
                    if !isExpanded {
                        print("[People] expanded intelligence for \(person.name)")
                    }
                    #endif
                }
            } label: {
                surfaceRow(person, sectionColor: sectionColor)
            }
            .buttonStyle(.plain)

            // ── Deep Layer (expandable) ──
            if isExpanded && !person.deepInsights.isEmpty {
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 14)
                deepLayer(person, sectionColor: sectionColor)
            }

            // ── Actions ──
            actionRow(person, sectionColor: sectionColor)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(person.isTargetIntent ? sectionColor.opacity(0.06) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    highlightedProfileId == person.id
                        ? Color.green.opacity(0.6)
                        : (person.isTargetIntent ? sectionColor.opacity(0.25) : Color.clear),
                    lineWidth: highlightedProfileId == person.id ? 2 : 1
                )
        )
        .scaleEffect(highlightedProfileId == person.id ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.3), value: highlightedProfileId)
        .id(person.id)
    }

    // MARK: - Surface Row

    private func surfaceRow(_ person: PersonIntelligence, sectionColor: Color) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                avatarView(person, color: sectionColor)
                if person.presence == .hereNow {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.name)
                        .font(.subheadline).fontWeight(.medium).foregroundColor(.white)
                    if person.connectionStatus == .accepted {
                        Image(systemName: "link").font(.system(size: 9)).foregroundColor(.green)
                    }
                    if person.isTargetIntent {
                        Image(systemName: "eye.fill").font(.system(size: 9)).foregroundColor(.cyan)
                    }
                }

                if !person.topTraits.isEmpty {
                    Text(person.topTraits.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                } else {
                    Text(person.distilledInsight)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                if let why = person.whyThisMatters {
                    Text("Why this matters: \(why)")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.9))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Expand indicator
            Image(systemName: expandedPersonId == person.id ? "chevron.up" : "chevron.down")
                .font(.system(size: 10)).foregroundColor(.gray.opacity(0.4))
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }

    // MARK: - Deep Layer

    private func deepLayer(_ person: PersonIntelligence, sectionColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let grouped = Dictionary(grouping: person.deepInsights, by: \.category)
            let order = ["Interaction", "Presence", "Relationship", "Action"]

            ForEach(order, id: \.self) { category in
                if let items = grouped[category], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(sectionColor.opacity(0.6))
                            .tracking(0.8)

                        ForEach(items) { item in
                            Text(item.text)
                                .font(.caption).foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Action Row

    private func actionRow(_ person: PersonIntelligence, sectionColor: Color) -> some View {
        HStack(spacing: 10) {
            actionButton(person.primaryAction, person: person, color: sectionColor)

            if let secondary = person.secondaryAction {
                actionButton(secondary, person: person, color: .white.opacity(0.5))
            }
        }
        .padding(.top, 4)
    }

    private func actionButton(_ action: PersonAction, person: PersonIntelligence, color: Color) -> some View {
        Button {
            handleAction(action, person: person)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.caption2)
                Text(action.label).font(.caption).fontWeight(.medium)
            }
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.12)).cornerRadius(8)
        }
    }

    // MARK: - Avatar

    private func avatarView(_ person: PersonIntelligence, color: Color) -> some View {
        Group {
            if let urlStr = person.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 42, height: 42).clipShape(Circle())
                    default:
                        initialsCircle(person.name, color: color)
                    }
                }
            } else {
                initialsCircle(person.name, color: color)
            }
        }
        .frame(width: 42, height: 42)
    }

    private func initialsCircle(_ name: String, color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.15))
            .overlay(
                Text(initials(name))
                    .font(.caption).fontWeight(.bold).foregroundColor(color)
            )
    }

    // MARK: - Action Handlers

    private func handleAction(_ action: PersonAction, person: PersonIntelligence) {
        switch action {
        case .find:
            #if DEBUG
            print("[PeopleAction] Find tapped for \(person.name)")
            #endif
            let attendees = attendeesService.attendees
            if let attendee = attendees.first(where: { $0.id == person.id }) {
                // Live attendee found — open the dedicated find/radar flow
                findTarget = attendee
            } else {
                // Not in live attendee list — build a minimal attendee for the find flow
                findTarget = EventAttendee(
                    id: person.id,
                    name: person.name,
                    avatarUrl: person.avatarUrl,
                    bio: nil,
                    skills: nil,
                    interests: nil,
                    energy: 0.5,
                    lastSeen: Date()
                )
            }

        case .message:
            #if DEBUG
            print("[PeopleAction] Message tapped for \(person.name)")
            #endif
            openConversation(profileId: person.id, name: person.name)

        case .viewProfile:
            #if DEBUG
            print("[PeopleAction] View Profile tapped for \(person.name)")
            #endif
            profileSheetTarget = ProfileSheetTarget(profileId: person.id)

        case .keepWatching:
            #if DEBUG
            print("[PeopleAction] Keep Watching tapped for \(person.name)")
            #endif
            break
        }
    }

    private func openConversation(profileId: UUID, name: String) {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true

        Task {
            do {
                _ = try await ConnectionService.shared.createConnectionIfNeeded(to: profileId.uuidString)
                print("[MessagingGate] auto-connected target=\(profileId.uuidString)")
                let convo = try await MessagingService.shared.getOrCreateConversation(with: profileId)
                print("[MessagingGate] opening conversation target=\(profileId.uuidString)")
                await MessagingService.shared.fetchMessages(conversationId: convo.id)
                await MainActor.run {
                    activeConversation = PeopleConversationTarget(
                        profileId: profileId, name: name, conversation: convo
                    )
                    isOpeningConversation = false
                }
            } catch {
                await MainActor.run {
                    isOpeningConversation = false
                    #if DEBUG
                    print("[People] ⚠️ Conversation open failed: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - Event Context Banner

    private func eventContextBanner(_ ctx: PeopleEventContext) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text("At \(ctx.eventName)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    navigationState.eventContext = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.08))
        )
        .padding(.horizontal)
    }

    // MARK: - Empty / Loading

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48)).foregroundColor(.gray.opacity(0.4))
            Text("No one here yet")
                .font(.title3).fontWeight(.semibold).foregroundColor(.white.opacity(0.6))
            Text("You'll see people appear as they arrive.\nJoin events to build your network over time.")
                .font(.subheadline).foregroundColor(.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading…").font(.subheadline).foregroundColor(.gray)
        }
    }

    // MARK: - Helpers

    private func initials(_ name: String) -> String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Sheet Targets

private struct ProfileSheetTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
}

private struct PeopleConversationTarget: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let conversation: Conversation
}
