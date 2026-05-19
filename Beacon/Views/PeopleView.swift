import SwiftUI


private func debugLog(_ message: @autoclosure () -> String, verbose: Bool = false) {
    if verbose {
        #if DEBUG_VERBOSE
        print(message())
        #endif
    } else {
        #if DEBUG
        print(message())
        #endif
    }
}

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
    @ObservedObject private var claimedGuestInteractions = ClaimedGuestInteractionService.shared

    @State private var expandedPersonId: UUID?
    @State private var activeConversation: PeopleConversationTarget?
    @State private var profileSheetTarget: ProfileSheetTarget?
    @State private var findTarget: EventAttendee?
    @State private var isOpeningConversation = false
    @State private var highlightedProfileId: UUID?
    @State private var lastFocusedTargetId: UUID?
    @State private var lastContextMode: PeopleContextMode?
    @State private var showFullRoster = false

    /// Sections are read from the controller, which handles debouncing
    /// and change detection. No direct computation in the view.
    private var sections: PeopleIntelligenceBuilder.Sections {
        controller.sections
    }

    private var isEmpty: Bool {
        sections.hereNow.isEmpty && sections.followUp.isEmpty && sections.notHere.isEmpty
    }

    private var contextHeader: (title: String, subtitle: String)? {
        guard let context = navigationState.peopleContext else { return nil }
        switch context.mode {
        case .liveNearby: return ("Here Now", "Live attendees nearby")
        case .recurringNearby: return ("Recurring nearby", "People you keep crossing paths with")
        case .unfinishedMomentum: return ("Momentum waiting", "A conversation is ready to continue")
        case .recommendedNow: return ("Recommended now", "People aligned with this moment")
        case .metBefore: return ("People worth reconnecting with", "Strong continuity from earlier events")
        case .strongMatch: return ("Strong matches", "People aligned with your current goal")
        case .waitingOnReply: return ("Waiting on reply", "Conversations that may need a nudge")
        case .followUpNeeded: return ("Follow-up needed", "High-value conversations to revisit")
        case .findTarget: return ("Find someone", "Focused navigation for a specific person")
        case .eventCluster: return ("Active event cluster", "People active around this event context")
        case .continuityFocus: return ("Continuity focus", "People you already have momentum with")
        }
    }

    private var flattenedPeople: [PersonIntelligence] {
        sections.hereNow + sections.followUp + sections.notHere
    }

    private var dominantPerson: PersonIntelligence? {
        if let highlighted = navigationState.peopleContext?.highlightedProfileId,
           let contextHit = flattenedPeople.first(where: { $0.id == highlighted }) {
            return contextHit
        }
        if let highlightedProfileId,
           let stickyHit = flattenedPeople.first(where: { $0.id == highlightedProfileId }) {
            return stickyHit
        }
        return flattenedPeople.sorted { $0.priorityScore > $1.priorityScore }.first
    }

    private var supportingPeople: [PersonIntelligence] {
        guard let dominantPerson else { return [] }
        return flattenedPeople
            .filter { $0.id != dominantPerson.id }
            .sorted { $0.priorityScore > $1.priorityScore }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if memory.isLoading && memory.relationships.isEmpty && attendeesService.attendees.isEmpty {
                ScrollView { loadingState.frame(maxWidth: .infinity) }
                    .tabbedScrollContentClearance(screen: "PeopleView")
            } else if isEmpty {
                ScrollView { emptyState.frame(maxWidth: .infinity) }
                    .tabbedScrollContentClearance(screen: "PeopleView")
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
        .refreshable {
            memory.requestRefresh(reason: "people-pull")
            claimedGuestInteractions.requestRefresh()
            SavedContactsStateService.shared.requestRefresh()
            PeopleRefreshCoordinator.shared.requestRefresh(reason: "people-pull")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        .onAppear {
            memory.requestRefresh(reason: "people-appear")
            claimedGuestInteractions.requestRefresh()
            SavedContactsStateService.shared.requestRefresh()
            PeopleRefreshCoordinator.shared.requestRefresh(reason: "people-appear")
        }
        .onChange(of: eventJoin.isEventJoined) { _, isJoined in
            // Clear event context when user leaves the event
            if !isJoined && navigationState.eventContext != nil {
                navigationState.setEventContext(nil, source: "PeopleView.eventJoinChanged")
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
                    debugLog("[FindFlow] Presented for \(attendee.name)")
                    #endif
                }
                .onDisappear {
                    #if DEBUG
                    debugLog("[FindFlow] Dismissed for \(attendee.name)")
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
                    if let contextHeader {
                        contextualHeader(contextHeader.title, subtitle: contextHeader.subtitle)
                    }

                    if let dominantPerson {
                        dominantMomentumCard(dominantPerson)
                    }

                    if !supportingPeople.isEmpty {
                        compactSectionBlock(
                            title: "Worth continuing",
                            subtitle: "Quiet signals around conversations with momentum",
                            people: supportingPeople
                        )
                    }

                    NavigationLink(value: PeopleRoute.nearifyContacts) {
                        nearifyContactsEntry
                    }
                     .buttonStyle(.plain)

                    if !flattenedPeople.isEmpty {
                        rosterDisclosure
                    }
                }
                 .responsiveContentContainer(maxWidth: 740)
                 .padding(.top, DesignTokens.titleToContent + 6)
                .padding(.bottom, DesignTokens.sectionSpacing + 8)
            }
            .tabbedScrollContentClearance(screen: "PeopleView")
            .onChange(of: navigationState.peopleFocusTarget) { _, target in
                guard let target = target else { return }
                #if DEBUG
                debugLog("[People] focus target received", verbose: true)
                #endif
                focusPersonIfLoaded(target: target, proxy: proxy)
            }
            .onChange(of: memory.relationships.count) { _, _ in
                guard let target = navigationState.peopleFocusTarget else { return }
                focusPersonIfLoaded(target: target, proxy: proxy)
            }
            .onChange(of: attendeesService.attendees.count) { _, _ in
                guard let target = navigationState.peopleFocusTarget else { return }
                focusPersonIfLoaded(target: target, proxy: proxy)
            }
            .onChange(of: navigationState.peopleContext) { _, context in
                guard let context else { return }
                guard lastContextMode != context.mode else { return }
                lastContextMode = context.mode
                #if DEBUG
                debugLog("[ContextualEntry] mode=\(context.mode.rawValue) reason=\(context.reason)")
                #endif
                if let highlighted = context.highlightedProfileId {
                    highlightedProfileId = highlighted
                    #if DEBUG
                    debugLog("[MomentumFocus] highlightedProfile=\(highlighted.uuidString.prefix(8))")
                    #endif
                }
            }
        }
    }

    private func contextualHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var rosterDisclosure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFullRoster.toggle()
                }
            } label: {
                HStack {
                    Text(showFullRoster ? "Hide attendee roster" : "Show attendee roster")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: showFullRoster ? "chevron.up" : "chevron.down")
                        .foregroundColor(.gray)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
            }
            .buttonStyle(.plain)

            if showFullRoster {
                if !sections.hereNow.isEmpty {
                    sectionBlock(title: "Still nearby", icon: "circle.fill", color: .white.opacity(0.6), subtitle: "People active around you", people: sections.hereNow)
                }
                if !sections.followUp.isEmpty {
                    sectionBlock(title: "Existing momentum", icon: "clock.arrow.circlepath", color: .white.opacity(0.6), subtitle: "Conversations that may be worth continuing", people: sections.followUp)
                }
                if !sections.notHere.isEmpty {
                    sectionBlock(title: "Familiar faces", icon: "sparkles", color: .white.opacity(0.55), subtitle: "People you may want to reconnect with", people: sections.notHere)
                }
            }
        }
        .onAppear {
            #if DEBUG
            debugLog("[PeopleHierarchy] dominant=\(dominantPerson?.id.uuidString.prefix(8) ?? "nil") supporting=\(supportingPeople.count) rosterExpanded=\(showFullRoster)")
            #endif
        }
    }

    private func focusPersonIfLoaded(target: PeopleFocusTarget, proxy: ScrollViewProxy) {
        if lastFocusedTargetId == target.profileId {
            #if DEBUG
            debugLog("[NavigationDestinationGuard] ignored duplicate selectedPerson id=\(target.profileId)", verbose: true)
            #endif
            return
        }

        let allIds = sections.hereNow.map(\.id) + sections.followUp.map(\.id) + sections.notHere.map(\.id)
        guard allIds.contains(target.profileId) else {
            #if DEBUG
            debugLog("[People] focus target pending; person not loaded yet", verbose: true)
            #endif
            return
        }

        #if DEBUG
        debugLog("[People] focus target matched/opened", verbose: true)
        #endif

        lastFocusedTargetId = target.profileId
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
            if navigationState.peopleFocusTarget == target {
                #if DEBUG
                debugLog("[VisibleRouteGuard] clearing consumed focus target id=\(target.profileId)", verbose: true)
                #endif
                navigationState.setPeopleFocusTarget(nil, source: "PeopleView.focusConsumed")
            }
        }
    }

    private var nearifyContactsEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundColor(.blue.opacity(0.9))
            VStack(alignment: .leading, spacing: 5) {
                Text("Saved to Contacts")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("People you’ve saved to Apple Contacts through Nearify")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))
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
            }
        }
        .onAppear {
            #if DEBUG
            debugLog("[ForEachIdentity] people section=\(title) using profileId identity count=\(people.count)", verbose: true)
            #endif
        }
    }

    private func compactSectionBlock(title: String, subtitle: String, people: [PersonIntelligence]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white.opacity(0.92))
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
            ForEach(people) { person in
                personCard(person, sectionColor: .white.opacity(0.55), compact: true)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Person Card (Surface + Deep)

    private func personCard(_ person: PersonIntelligence, sectionColor: Color, compact: Bool = false) -> some View {
        let isExpanded = expandedPersonId == person.id
        let strengthAccent = relationshipAccent(for: person.relationshipState)

        return VStack(alignment: .leading, spacing: 0) {
            // ── Surface Layer ──
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedPersonId = isExpanded ? nil : person.id
                    #if DEBUG
                    if !isExpanded {
                        debugLog("[People] expanded intelligence for \(person.name)", verbose: true)
                    }
                    #endif
                }
            } label: {
                surfaceRow(person, sectionColor: sectionColor, compact: compact)
            }
            .buttonStyle(.plain)

            // ── Deep Layer (expandable) ──
            if isExpanded && !person.deepInsights.isEmpty && !compact {
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 14)
                deepLayer(person, sectionColor: sectionColor)
            }

            // ── Actions ──
            actionRow(person, sectionColor: sectionColor, compact: compact)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(person.isTargetIntent ? sectionColor.opacity(compact ? 0.03 : 0.045) : Color.white.opacity(compact ? 0.03 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    highlightedProfileId == person.id
                        ? Color.white.opacity(0.35)
                        : (person.isTargetIntent ? sectionColor.opacity(0.14) : strengthAccent.opacity(0.16)),
                    lineWidth: highlightedProfileId == person.id ? 1.5 : 0.8
                )
        )
        .scaleEffect(highlightedProfileId == person.id ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.3), value: highlightedProfileId)
        .id(person.id)
    }

    private func relationshipAccent(for state: PeopleRelationshipState) -> Color {
        switch state {
        case .encountered: return .gray
        case .repeated: return .blue
        case .connected: return .green
        case .savedContact: return .green.opacity(0.9)
        }
    }

    // MARK: - Surface Row

    private func surfaceRow(_ person: PersonIntelligence, sectionColor: Color, compact: Bool = false) -> some View {
        return HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                avatarView(person, color: sectionColor)
                if person.presence == .hereNow {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(person.displayName)
                        .font(.body.weight(.semibold)).foregroundColor(.white)
                    let relationshipState = person.relationshipState
                    relationshipBadge(for: relationshipState)
                        .onAppear {
                            logRelationshipState(relationshipState)
                        }
                    if person.isTargetIntent {
                        Image(systemName: "eye.fill").font(.system(size: 9)).foregroundColor(.cyan)
                    }
                }

                if person.relationshipState == .encountered || person.relationshipState == .repeated {
                    Text(person.distilledInsight)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                } else if !person.topTraits.isEmpty {
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

                if let why = humanizedWhyText(for: person) {
                    Text(why)
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.9))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Expand indicator
            if !compact {
                Image(systemName: expandedPersonId == person.id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10)).foregroundColor(.gray.opacity(0.4))
            }
        }
        .padding(.vertical, compact ? 8 : 10).padding(.horizontal, 14)
    }

    private func logRelationshipState(_ state: PeopleRelationshipState) {
        #if DEBUG
        debugLog("[PeopleRelationshipUI] Rendered state: \(state)", verbose: true)
        #endif
    }

    @ViewBuilder
    private func relationshipBadge(for state: PeopleRelationshipState) -> some View {
        switch state {
        case .encountered:
            Circle()
                .stroke(Color.gray.opacity(0.7), lineWidth: 1)
                .frame(width: 10, height: 10)
        case .repeated:
            ZStack {
                Circle().stroke(Color.blue.opacity(0.55), lineWidth: 1).frame(width: 11, height: 11)
                Circle().stroke(Color.blue.opacity(0.35), lineWidth: 1).frame(width: 7, height: 7)
            }
        case .connected:
            Image(systemName: "link")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.green.opacity(0.85))
        case .savedContact:
            Circle()
                .fill(Color.green.opacity(0.9))
                .frame(width: 12, height: 12)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                )
        }
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

    private func actionRow(_ person: PersonIntelligence, sectionColor: Color, compact: Bool) -> some View {
        HStack(spacing: 10) {
            actionButton(person.primaryAction, person: person, color: sectionColor, compact: compact)
        }
        .padding(.top, 4)
    }

    private func actionButton(_ action: PersonAction, person: PersonIntelligence, color: Color, compact: Bool) -> some View {
        Button {
            handleAction(action, person: person)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.caption2)
                Text(primaryActionLabel(for: action, person: person)).font(.caption).fontWeight(.medium)
            }
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(compact ? 0.08 : 0.12)).cornerRadius(8)
        }
    }

    private func dominantMomentumCard(_ person: PersonIntelligence) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start here")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
            HStack(spacing: 12) {
                avatarView(person, color: .white)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                    if let continuity = humanizedWhyText(for: person) {
                        Text(continuity)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            Text(dominantHeadline(for: person))
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            actionButton(person.primaryAction, person: person, color: .white, compact: false)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal)
        .onAppear {
            #if DEBUG
            debugLog("[DominantRecommendation] person=\(person.id.uuidString.prefix(8)) action=\(person.primaryAction.label)")
            debugLog("[ActionPriority] primary=\(person.primaryAction.label) person=\(person.id.uuidString.prefix(8))")
            #endif
        }
    }

    private func dominantHeadline(for person: PersonIntelligence) -> String {
        switch navigationState.peopleContext?.mode {
        case .unfinishedMomentum, .continuityFocus:
            return "This conversation may be worth continuing."
        case .liveNearby:
            return "\(person.displayName) is nearby."
        case .recommendedNow:
            return "You already have context here."
        default:
            return "You already have context here."
        }
    }

    private func humanizedWhyText(for person: PersonIntelligence) -> String? {
        if let existing = person.whyThisMatters, !existing.isEmpty {
            return existing.replacingOccurrences(of: "Why this matters:", with: "").trimmingCharacters(in: .whitespaces)
        }
        switch person.presence {
        case .hereNow: return "You both stayed active nearby."
        case .followUp: return "You already broke the ice."
        case .notHere: return "You've crossed paths before."
        }
    }

    private func primaryActionLabel(for action: PersonAction, person: PersonIntelligence) -> String {
        switch action {
        case .find: return person.presence == .hereNow ? "Find them" : "Find"
        case .message: return "Continue"
        case .viewProfile: return "Open thread"
        case .keepWatching: return "Keep in view"
        }
    }

    // MARK: - Avatar

    private func avatarView(_ person: PersonIntelligence, color: Color) -> some View {
        Group {
            if let urlStr = person.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        #if DEBUG
                        let _ = debugLog("[PeopleAvatar] source=photo profile=\(person.id.uuidString.prefix(8))")
                        #endif
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 42, height: 42).clipShape(Circle())
                    default:
                        #if DEBUG
                        let _ = debugLog("[PeopleAvatar] source=fallback profile=\(person.id.uuidString.prefix(8))")
                        #endif
                        initialsCircle(person.displayName, color: color)
                    }
                }
            } else {
                #if DEBUG
                let _ = debugLog("[PeopleAvatar] source=fallback profile=\(person.id.uuidString.prefix(8))")
                #endif
                initialsCircle(person.displayName, color: color)
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
            debugLog("[PeopleAction] Find tapped for \(person.name)")
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
            debugLog("[PeopleAction] Message tapped for \(person.name)")
            #endif
            openConversation(profileId: person.id, name: person.name)

        case .viewProfile:
            #if DEBUG
            debugLog("[PeopleAction] View Profile tapped for \(person.name)")
            #endif
            profileSheetTarget = ProfileSheetTarget(profileId: person.id)

        case .keepWatching:
            #if DEBUG
            debugLog("[PeopleAction] Keep Watching tapped for \(person.name)")
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
                debugLog("[MessagingGate] auto-connected target=\(profileId.uuidString)")
                let convo = try await MessagingService.shared.getOrCreateConversation(with: profileId)
                debugLog("[MessagingGate] opening conversation target=\(profileId.uuidString)")
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
                    debugLog("[People] ⚠️ Conversation open failed: \(error)")
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
                    navigationState.setEventContext(nil, source: "PeopleView.eventJoinChanged")
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
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48)).foregroundColor(.gray.opacity(0.4))
            Text("You're early.")
                .font(.title3).fontWeight(.semibold).foregroundColor(.white.opacity(0.6))
            Text("People will appear here as they arrive.")
                .font(.subheadline).foregroundColor(.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Looking around…").font(.subheadline).foregroundColor(.gray)
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
