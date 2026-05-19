import SwiftUI
import Combine


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
    @State private var semanticTick = 0

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
        case .liveNearby: return ("Here now", "People at this event")
        case .recurringNearby: return ("Crossing paths again", "People you keep running into")
        case .unfinishedMomentum: return ("A conversation is waiting", "Pick up where you left off")
        case .recommendedNow: return ("Worth saying hello", "People aligned with this moment")
        case .metBefore: return ("Familiar faces", "People with continuity")
        case .strongMatch: return ("Aligned with your goal", "People who may be useful right now")
        case .waitingOnReply: return ("Still waiting", "Conversations that may need a nudge")
        case .followUpNeeded: return ("Worth following up", "Threads worth continuing")
        case .findTarget: return ("Looking for someone", "Focused navigation")
        case .eventCluster: return ("Around this event", "People active in this orbit")
        case .continuityFocus: return ("You already have momentum", "Threads that are warm")
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

    private var attendeeLookup: [UUID: EventAttendee] {
        Dictionary(uniqueKeysWithValues: attendeesService.attendees.map { ($0.id, $0) })
    }

    private func freshnessAge(for person: PersonIntelligence) -> TimeInterval? {
        attendeeLookup[person.id].map { Date().timeIntervalSince($0.lastSeen) }
    }

    private func liveConfidence(for person: PersonIntelligence) -> Double {
        let bleBoost: Double = (person.presenceSource == .ble || person.presenceSource == .bleAndBackend) ? 0.55 : 0.0
        let backendBoost: Double = (person.presenceSource == .backend || person.presenceSource == .bleAndBackend) ? 0.25 : 0.0
        let freshnessBoost: Double = freshnessAge(for: person).map { max(0, 0.30 - min($0, 300) / 1000) } ?? 0
        let overlapBoost: Double = person.presence == .hereNow ? 0.12 : (person.presence == .followUp ? 0.06 : 0)
        return min(1.0, bleBoost + backendBoost + freshnessBoost + overlapBoost)
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

        .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
            semanticTick += 1
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
                        dominantMomentSurface(dominantPerson)
                    }

                    if !supportingPeople.isEmpty {
                        activeOrbitSection
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
            .animation(.easeInOut(duration: 0.25), value: flattenedPeople.map(\.id))
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
    private var activeOrbitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your orbit")
                .font(.headline.weight(.semibold))
                .foregroundColor(.white.opacity(0.88))
            ForEach(supportingPeople) { person in
                personCard(person, sectionColor: .white.opacity(0.45), compact: true)
            }
        }
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
                    Text(showFullRoster ? "Hide quiet continuity" : "Show quiet continuity")
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
                    sectionBlock(title: "Recently seen", icon: "clock", color: .white.opacity(0.55), subtitle: "Recent live presence", people: sections.hereNow)
                }
                if !sections.followUp.isEmpty {
                    sectionBlock(title: "Prior momentum", icon: "clock.arrow.circlepath", color: .white.opacity(0.55), subtitle: "Threads with continuity", people: sections.followUp)
                }
                if !sections.notHere.isEmpty {
                    sectionBlock(title: "Quiet orbit", icon: "circle.dotted", color: .white.opacity(0.5), subtitle: "Historical continuity", people: sections.notHere)
                }
            }
        }
        .onAppear {
            #if DEBUG
            debugLog("[PeopleSectionPriority] dominant=\(dominantPerson?.id.uuidString.prefix(8) ?? "nil") supporting=\(supportingPeople.count) rosterExpanded=\(showFullRoster)")
            debugLog("[PeopleActionSurface] live=\(sections.hereNow.count) followUp=\(sections.followUp.count) passive=\(sections.notHere.count)")
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
                    Text(title)
                        .font(.caption).foregroundColor(color.opacity(0.7))
                    Spacer()
                    Text("\(people.count)").font(.caption2).foregroundColor(.gray.opacity(0.5))
                }
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
        .opacity(staleVisualFactor(for: person))
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
                Text(person.displayName)
                    .font(.body.weight(.semibold)).foregroundColor(.white)

                Text(dominantHeadline(for: person))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(1)

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
        .onAppear {
            #if DEBUG
            debugLog("[PeopleDominantAction] person=\(person.id.uuidString.prefix(8)) cta=\(primaryActionLabel(for: person.primaryAction, person: person))")
            #endif
        }
    }

    private func actionButton(_ action: PersonAction, person: PersonIntelligence, color: Color, compact: Bool) -> some View {
        Button {
            handleAction(action, person: person)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.caption2)
                Text(primaryActionLabel(for: action, person: person)).font(.caption).fontWeight(.medium)
            }
            .foregroundColor(person.presence == .hereNow ? .black : color)
            .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
            .background((person.presence == .hereNow ? Color.white.opacity(0.95) : color.opacity(compact ? 0.08 : 0.12)))
            .cornerRadius(10)
        }
    }

    private func dominantMomentSurface(_ person: PersonIntelligence) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                avatarView(person, color: .white)
                    .frame(width: 72, height: 72)
                Text(person.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                livePulseDot
            }
            Text(dominantHeadline(for: person))
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            actionButton(person.primaryAction, person: person, color: .white, compact: false)
        }
         .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.16), lineWidth: 1.1))
        .padding(.horizontal)
        .onAppear {
            #if DEBUG
            debugLog("[PeopleDominantContext] person=\(person.id.uuidString.prefix(8)) action=\(person.primaryAction.label) confidence=\(String(format: "%.2f", liveConfidence(for: person)))")
            debugLog("[PeoplePresenceWeight] person=\(person.id.uuidString.prefix(8)) freshnessAge=\(Int(freshnessAge(for: person) ?? -1)) source=\(person.presenceSource.rawValue) dominance=live-signal")
            #endif
        }
    }

    private func dominantHeadline(for person: PersonIntelligence) -> String {
        let lines: [String]
        switch person.presence {
        case .hereNow:
            lines = ["Still nearby.", "You both are active right now.", "You already crossed paths tonight.", "Conversation momentum is live."]
        case .followUp:
            lines = ["Easy reconnect.", "Conversation is warm.", "You already have context.", "Momentum is waiting."]
        case .notHere:
            lines = ["Prior connection.", "Familiar thread.", "Quiet continuity.", "Reconnect when ready."]
        }
        let pick = lines[(semanticTick + Int(person.priorityScore.rounded())) % lines.count]
        #if DEBUG
        debugLog("[PeopleSemanticRotation] person=\(person.id.uuidString.prefix(8)) phrase=\(pick)")
        #endif
        return pick
    }
    private func primaryActionLabel(for action: PersonAction, person: PersonIntelligence) -> String {
        switch action {
        case .find:
            let canFind = canShowFind(for: person)
            #if DEBUG
            debugLog("[PeopleCTAResolution] person=\(person.id.uuidString.prefix(8)) confidence=\(String(format: "%.2f", liveConfidence(for: person))) source=\(person.presenceSource.rawValue) reason=\(canFind ? "live-proximity" : "softened-cta")")
            debugLog("[PeopleUrgency] person=\(person.id.uuidString.prefix(8)) state=\(person.presence.rawValue) weighting=\(String(format: "%.2f", liveConfidence(for: person)))")
            #endif
            return canFind ? "Nearby" : "Continue"
        case .message: return "Continue"
        case .viewProfile: return "Reconnect"
        case .keepWatching: return "Still nearby"
        }
    }

    private func canShowFind(for person: PersonIntelligence) -> Bool {
        if person.presenceSource == .ble || person.presenceSource == .bleAndBackend { return true }
        return liveConfidence(for: person) >= 0.72
    }

    private func staleVisualFactor(for person: PersonIntelligence) -> Double {
        guard let age = freshnessAge(for: person) else { return 0.78 }
        if age < 60 { return 1.0 }
        if age < 300 { return 0.88 }
        #if DEBUG
        debugLog("[PeopleTemporalTruth] person=\(person.id.uuidString.prefix(8)) freshnessAge=\(Int(age))s staleDowngrade=expired")
        #endif
        return 0.62
    }

        private var livePulseDot: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.3)).frame(width: 20, height: 20)
                .scaleEffect(semanticTick % 2 == 0 ? 0.85 : 1.05)
                .animation(.easeInOut(duration: 1.4), value: semanticTick)
            Circle().fill(Color.green).frame(width: 9, height: 9)
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
            guard canShowFind(for: person) else {
                #if DEBUG
                debugLog("[PeopleCTAResolution] person=\(person.id.uuidString.prefix(8)) cta=Continue reason=not-discoverable")
                #endif
                openConversation(profileId: person.id, name: person.name)
                return
            }
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
            Text("The room is still settling.")
                .font(.title3).fontWeight(.semibold).foregroundColor(.white.opacity(0.6))
            Text("People are beginning to appear nearby. Signals become clearer as activity increases.")
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
