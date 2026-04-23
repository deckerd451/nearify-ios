import SwiftUI
import Supabase

struct NetworkView: View {
    @ObservedObject private var attendees = EventAttendeesService.shared
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var modeState = EventModeState.shared
    @ObservedObject private var peopleController = PeopleIntelligenceController.shared

    @State private var showMockAttendees = false
    @State private var showSettings = false
    @State private var showPresenceTestResult = false
    @State private var selectedAttendee: EventAttendee?
    @State private var showLeaveConfirmation = false
    @State private var activeConversation: NetworkConversationTarget?
    @State private var profileSheetTarget: NetworkProfileTarget?

    @State private var guestConnections: [GuestConnection] = []

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                switch modeState.membership {
                case .notInEvent, .joined:
                    inactiveState
                case .inEvent, .inactive:
                    activeEventView
                case .dormant:
                    dormantState
                case .left:
                    exitedState
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(item: $selectedAttendee) { attendee in
                FindAttendeeView(attendee: attendee)
            }
            .sheet(item: $activeConversation) { target in
                ConversationView(
                    targetProfileId: target.profileId,
                    preloadedConversation: nil,
                    preloadedName: target.name
                )
            }
            .sheet(item: $profileSheetTarget) { target in
                NavigationStack {
                    FeedProfileDetailView(profileId: target.profileId)
                }
            }
            .confirmationDialog(
                "Leave Event",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Event", role: .destructive) {
                    Task { await eventJoin.leaveEvent() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your connections and messages will be kept. You can rejoin by scanning the QR code again.")
            }
            .task {
                peopleController.forceRebuild(reason: "network-appear")
                await refreshPeopleSections()
            }
            .onChange(of: attendees.attendees) { _, _ in
                peopleController.scheduleRebuild(reason: "network-attendees")
                Task { await refreshPeopleSections() }
            }
            .onChange(of: modeState.membership) { _, _ in
                peopleController.scheduleRebuild(reason: "network-membership")
                Task { await refreshPeopleSections() }
            }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    attendees.refresh()
                }
            }
        }
    }

    private var stateBanner: some View {
        let state = modeState.membership

        return HStack(spacing: 8) {
            Image(systemName: state.iconName)
                .foregroundColor(state.displayColor)
                .font(.system(size: 12))

            Text(state.displayLabel)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(state.displayColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(state.displayColor.opacity(0.15)))
    }

    @ViewBuilder
    private var reconnectBanner: some View {
        if let context = eventJoin.reconnectContext {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reconnect to \(context.eventName)?")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)

                        Text("You were at this event recently")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await eventJoin.joinEvent(eventID: context.eventId) }
                    } label: {
                        Text("Rejoin")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }

                    Button {
                        eventJoin.dismissReconnect()
                    } label: {
                        Text("Dismiss")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
        }
    }

    private var inactiveState: some View {
        ScrollView {
            VStack(spacing: 24) {
                reconnectBanner

                VStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)

                    Text("No Active Event")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text("Join an event to see nearby attendees")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    Text("Your connections and messages are always available in the Feed.")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.top, 24)
        }
    }

    private var exitedState: some View {
        ScrollView {
            VStack(spacing: 24) {
                reconnectBanner

                VStack(spacing: 16) {
                    stateBanner

                    if let name = modeState.membership.eventName {
                        Text(name)
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text("You left this event.")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    Text("Your connections and messages are still available in the Feed.")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)

                    Button {
                        eventJoin.acknowledgeExit()
                    } label: {
                        Text("OK")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                }
            }
            .padding(.top, 24)
        }
    }

    private var dormantState: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)

                    if let name = modeState.membership.eventName {
                        Text(name)
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    Text("You're still part of this event")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))

                    Text("Your session is paused. Resume to reconnect with nearby attendees.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        Task { await eventJoin.resumeFromDormant() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Resume")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange)
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 40)

                    Button {
                        showLeaveConfirmation = true
                    } label: {
                        Text("Leave Event")
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
            }
            .padding(.top, 40)
        }
    }

    private var activeEventView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                eventHeader

                if peopleSections.isEmpty {
                    emptyState
                } else {
                    ForEach(peopleSections) { section in
                        peopleSectionView(section)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    private var eventHeader: some View {
        VStack(spacing: 8) {
            if let eventName = eventJoin.currentEventName ?? presence.currentEvent {
                Text(eventName)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            stateBanner

            if case .inEvent = modeState.membership {
                Button {
                    showLeaveConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12))
                        Text("Leave Event")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundColor(.gray)

            Text("No people to show yet")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text("People appear here as you connect and others join this event.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func peopleSectionView(_ section: NetworkPeopleSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.gray)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            VStack(spacing: 10) {
                switch section.kind {
                case .connected(let people):
                    ForEach(people) { person in
                        personRow(person, section: .connected)
                    }

                case .hereNow(let people):
                    ForEach(people) { person in
                        personRow(person, section: .hereNow)
                    }

                case .guests(let guests):
                    ForEach(guests) { guest in
                        guestRow(guest)
                    }
                }
            }
        }
    }

    private func personRow(_ person: PersonIntelligence, section: NetworkPeopleSection.VisualSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(imageUrl: person.avatarUrl, name: person.name, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(person.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)

                        if person.connectionStatus == .accepted {
                            Image(systemName: "link")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }

                        if section == .connected && person.presence == .hereNow {
                            Text("Here now")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.cyan.opacity(0.2)))
                        }
                    }

                    Text(person.distilledInsight)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                if section == .hereNow {
                    actionButton(.find, person: person, tint: .cyan)
                } else {
                    ForEach(availableActions(for: person, section: section), id: \.label) { action in
                        actionButton(action, person: person, tint: actionTint(action))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func availableActions(for person: PersonIntelligence, section: NetworkPeopleSection.VisualSection) -> [PersonAction] {
        let raw = [person.primaryAction, person.secondaryAction].compactMap { $0 }
        var actions: [PersonAction] = []

        for action in raw where !actions.contains(where: { $0.label == action.label }) {
            if section == .hereNow && action == .keepWatching {
                continue
            }
            actions.append(action)
        }

        if section == .hereNow && !actions.contains(where: { $0 == .find }) {
            actions.insert(.find, at: 0)
        }

        return actions
    }

    private func actionTint(_ action: PersonAction) -> Color {
        switch action {
        case .find:
            return .cyan
        case .message:
            return .green
        case .viewProfile:
            return .white.opacity(0.8)
        case .keepWatching:
            return .orange
        }
    }

    private func actionButton(_ action: PersonAction, person: PersonIntelligence, tint: Color) -> some View {
        Button {
            handleAction(action, person: person)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon)
                    .font(.caption2)
                Text(action.label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func handleAction(_ action: PersonAction, person: PersonIntelligence) {
        switch action {
        case .find:
            if let attendee = displayAttendees.first(where: { $0.id == person.id }) {
                selectedAttendee = attendee
            }
        case .message:
            activeConversation = NetworkConversationTarget(profileId: person.id, name: person.name)
        case .viewProfile:
            profileSheetTarget = NetworkProfileTarget(profileId: person.id)
        case .keepWatching:
            break
        }
    }

    private func guestRow(_ guest: GuestConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 22))
                .foregroundColor(.purple.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.04))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Guest")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text(guest.contextLine)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            Spacer()

            Text(guest.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Info")) {
                    HStack {
                        Text("Event")
                        Spacer()
                        Text(eventJoin.currentEventName ?? presence.currentEvent ?? "None")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("State")
                        Spacer()
                        Text(modeState.membership.displayLabel)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Nearby Attendees")
                        Spacer()
                        Text("\(attendees.attendeeCount)")
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Diagnostics")) {
                    Toggle("Show Mock Attendees", isOn: $showMockAttendees)

                    Button(action: {
                        Task {
                            await EventPresenceService.shared.debugWritePresenceNow()
                            await MainActor.run { showPresenceTestResult = true }
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.up.doc.fill")
                            Text("Test Presence Write")
                            Spacer()
                        }
                    }
                    .alert("Presence Test Result", isPresented: $showPresenceTestResult) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text(presence.debugStatus)
                    }
                }
            }
            .navigationTitle("Event Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    private var displayAttendees: [EventAttendee] {
        showMockAttendees ? mockAttendees : attendees.attendees
    }

    private var currentEventName: String? {
        eventJoin.currentEventName ?? presence.currentEvent
    }

    private var peopleSections: [NetworkPeopleSection] {
        adaptedPeopleSections(
            oldModel: peopleController.sections,
            guests: guestConnections
        )
    }

    private func adaptedPeopleSections(
        oldModel: PeopleIntelligenceBuilder.Sections,
        guests: [GuestConnection]
    ) -> [NetworkPeopleSection] {
        var sections: [NetworkPeopleSection] = []
        var usedIds = Set<UUID>()

        let connectedFromFollowUp = oldModel.followUp
        let connectedFromNotHere = oldModel.notHere.filter { $0.connectionStatus == .accepted }
        let connectedMerged = dedupedPeople(connectedFromFollowUp + connectedFromNotHere, usedIds: &usedIds)

        if !connectedMerged.isEmpty {
            sections.append(NetworkPeopleSection(kind: .connected(connectedMerged)))
        }

        let hereNowMerged = dedupedPeople(oldModel.hereNow, usedIds: &usedIds)
        if !hereNowMerged.isEmpty {
            sections.append(NetworkPeopleSection(kind: .hereNow(hereNowMerged)))
        }

        if !guests.isEmpty {
            sections.append(NetworkPeopleSection(kind: .guests(guests)))
        }

        return sections
    }

    private func dedupedPeople(_ people: [PersonIntelligence], usedIds: inout Set<UUID>) -> [PersonIntelligence] {
        var result: [PersonIntelligence] = []
        for person in people where !usedIds.contains(person.id) {
            result.append(person)
            usedIds.insert(person.id)
        }
        return result
    }

    private func refreshPeopleSections() async {
        guestConnections = await NetworkPeopleService.shared.fetchUnclaimedGuests(currentEventName: currentEventName)
    }

    private var mockAttendees: [EventAttendee] {
        [
            EventAttendee(
                id: UUID(),
                name: "Alice Johnson",
                avatarUrl: nil,
                bio: nil,
                skills: [],
                interests: [],
                energy: 0.8,
                lastSeen: Date().addingTimeInterval(-10)
            ),
            EventAttendee(
                id: UUID(),
                name: "Bob Smith",
                avatarUrl: nil,
                bio: nil,
                skills: [],
                interests: [],
                energy: 0.6,
                lastSeen: Date().addingTimeInterval(-45)
            ),
            EventAttendee(
                id: UUID(),
                name: "Carol Davis",
                avatarUrl: nil,
                bio: nil,
                skills: [],
                interests: [],
                energy: 0.4,
                lastSeen: Date().addingTimeInterval(-120)
            )
        ]
    }
}

private struct NetworkPeopleSection: Identifiable {
    enum VisualSection {
        case connected
        case hereNow
    }

    enum Kind {
        case connected([PersonIntelligence])
        case hereNow([PersonIntelligence])
        case guests([GuestConnection])
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .connected:
            return "Connected"
        case .hereNow:
            return "Here now"
        case .guests:
            return "Guests"
        }
    }
}

private struct NetworkConversationTarget: Identifiable {
    let profileId: UUID
    let name: String
    var id: UUID { profileId }
}

private struct NetworkProfileTarget: Identifiable {
    let profileId: UUID
    var id: UUID { profileId }
}

struct GuestConnection: Identifiable {
    let id: UUID
    let createdAt: Date
    let contextLine: String
}

@MainActor
final class NetworkPeopleService {
    static let shared = NetworkPeopleService()

    private let supabase = AppEnvironment.shared.supabaseClient

    private init() { }

    func fetchUnclaimedGuests(currentEventName: String?) async -> [GuestConnection] {
        guard let currentProfileId = AuthService.shared.currentUser?.id else {
            return []
        }

        do {
            let rows: [GhostInteractionRow] = try await supabase
                .from("interaction_edges")
                .select("id,from_ghost_id,to_profile_id,claimed_by_profile_id,created_at")
                .eq("to_profile_id", value: currentProfileId.uuidString)
                .not("from_ghost_id", operator: .is, value: "null")
                .is("claimed_by_profile_id", value: nil)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            return rows.map {
                GuestConnection(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    contextLine: guestContextLine(eventName: currentEventName)
                )
            }
        } catch {
            print("[NetworkPeople] Failed to load guests: \(error)")
            return []
        }
    }

    private func guestContextLine(eventName: String?) -> String {
        if let eventName, !eventName.isEmpty {
            return "Connected with you at \(eventName)"
        }

        return "Unclaimed connection"
    }
}

private struct GhostInteractionRow: Decodable {
    let id: UUID
    let fromGhostId: UUID?
    let toProfileId: UUID
    let claimedByProfileId: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case fromGhostId = "from_ghost_id"
        case toProfileId = "to_profile_id"
        case claimedByProfileId = "claimed_by_profile_id"
        case createdAt = "created_at"
    }
}
