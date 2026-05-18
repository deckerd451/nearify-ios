import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @State private var showScanner = false

    private let surfaceHorizontalPadding: CGFloat = 20

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    contextualStateLayer
                    dominantActionLayer
                    momentumLayer
                    ambientIntelligenceLayer
                }
                .padding(.horizontal, surfaceHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .background(homeBackground.ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { attendeesService.refresh() }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(selectedTab: $selectedTab)
            }
            .navigationDestination(for: UUID.self) { attendeeId in
                if let attendee = attendeesService.attendees.first(where: { $0.id == attendeeId }) {
                    PersonDetailView(attendee: attendee)
                }
            }
        }
    }

    // MARK: - Layer 1: Dynamic Contextual State

    private var contextualStateLayer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nearify")
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1.6)

            Text(primaryNarrative)
                .font(.system(size: 31, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if isEventActive {
                eventContinuityPill
            } else {
                consentPill
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(contextualGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.48), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 10)
    }

    private var eventContinuityPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
            Text(eventDisplayName)
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.72)))
    }

    private var consentPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundColor(.blue.opacity(0.75))
            Text("Only event presence you choose to share is used here.")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.72)))
    }

    // MARK: - Layer 2: Single Dominant Action

    private var dominantActionLayer: some View {
        Button(action: performDominantAction) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(dominantAction.tint.opacity(0.14))
                    Image(systemName: dominantAction.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(dominantAction.tint)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Next best step")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(1)
                    Text(dominantAction.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    if let subtitle = dominantAction.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.right")
                    .font(.headline)
                    .foregroundColor(dominantAction.tint)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(dominantAction.tint.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layer 3: Momentum Feed

    private var momentumLayer: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Momentum",
                subtitle: "A few signals from your evolving social world."
            )

            VStack(spacing: 12) {
                ForEach(momentumCards) { card in
                    MomentumCardView(card: card)
                }

                if isEventActive && !attendeesService.attendees.isEmpty {
                    nearbyPeopleStrip
                }
            }
        }
    }

    private var nearbyPeopleStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People becoming accessible now")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            VStack(spacing: 10) {
                ForEach(Array(attendeesService.attendees.prefix(3))) { attendee in
                    NavigationLink(value: attendee.id) {
                        HStack(spacing: 12) {
                            InitialsBubble(attendee: attendee)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attendee.name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                Text(attendee.detailSubtitleText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(attendee.lastSeenText)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.systemBackground).opacity(0.72))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: - Layer 4: Ambient Intelligence

    private var ambientIntelligenceLayer: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Quiet patterns",
                subtitle: "Subtle continuity, shown only when it can be useful."
            )

            VStack(spacing: 10) {
                ForEach(ambientSignals) { signal in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: signal.icon)
                            .font(.subheadline)
                            .foregroundColor(signal.tint.opacity(0.8))
                            .frame(width: 22)
                        Text(signal.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground).opacity(0.62))
                    )
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Intelligence Synthesis

    private var isEventActive: Bool {
        eventJoin.isEventJoined || presence.currentEvent != nil
    }

    private var eventDisplayName: String {
        eventJoin.currentEventName ?? presence.currentEvent ?? "this event"
    }

    private var primaryNarrative: String {
        guard isEventActive else {
            return "Your social world starts to take shape when you enter a real room."
        }

        let activeCount = attendeesService.attendeeCount
        if activeCount >= 3 {
            return "Several people in your orbit are present at \(eventDisplayName)."
        }

        if activeCount == 2 {
            return "Two people are close enough for this room to start feeling familiar."
        }

        if activeCount == 1, let first = attendeesService.attendees.first {
            return "\(first.firstName) is nearby at \(eventDisplayName)."
        }

        if attendeesService.isLoading {
            return "Nearify is looking for the shape of the room."
        }

        return "You are checked in. Momentum can begin here."
    }

    private var dominantAction: DominantHomeAction {
        if !isEventActive {
            return DominantHomeAction(
                title: "Join a room with Nearify",
                subtitle: "Scan an event QR when you want your presence to become part of the moment.",
                icon: "qrcode.viewfinder",
                tint: .blue,
                kind: .scan
            )
        }

        if attendeesService.attendeeCount > 0 {
            return DominantHomeAction(
                title: "Notice who is here",
                subtitle: "Start with the people currently accessible, then choose what feels natural.",
                icon: "person.2.wave.2.fill",
                tint: .green,
                kind: .network
            )
        }

        return DominantHomeAction(
            title: "Stay present at \(eventDisplayName)",
            subtitle: "Nearby people will appear as they choose to share presence in this event.",
            icon: "sparkles",
            tint: .purple,
            kind: .refresh
        )
    }

    private var momentumCards: [HomeMomentumCard] {
        var cards: [HomeMomentumCard] = []

        if isEventActive {
            cards.append(HomeMomentumCard(
                icon: "mappin.and.ellipse",
                title: "You are part of \(eventDisplayName)",
                body: "Attendance is the first signal. Nearify treats showing up as meaningful momentum.",
                tint: .green
            ))
        } else {
            cards.append(HomeMomentumCard(
                icon: "circle.dotted",
                title: "No room is active yet",
                body: "When you join an event, Home shifts from a static start screen into continuity from that room.",
                tint: .blue
            ))
        }

        let activeCount = attendeesService.attendeeCount
        if activeCount > 0 {
            cards.append(HomeMomentumCard(
                icon: "person.2.fill",
                title: "\(activeCount) nearby \(activeCount == 1 ? "person" : "people") can become a next step",
                body: "Presence stays contextual here. It helps you recognize opportunity without turning people into metrics.",
                tint: .mint
            ))
        }

        if let sharedTheme = strongestSharedTheme {
            cards.append(HomeMomentumCard(
                icon: "point.3.connected.trianglepath.dotted",
                title: "A \(sharedTheme) thread is visible",
                body: "A few people here mention similar interests or skills. That can make a first conversation easier.",
                tint: .orange
            ))
        }

        if isEventActive && activeCount == 0 && !attendeesService.isLoading {
            cards.append(HomeMomentumCard(
                icon: "leaf.fill",
                title: "The room is still forming",
                body: "You are not starting from zero. Your check-in gives Nearify a place to remember from.",
                tint: .teal
            ))
        }

        cards.append(HomeMomentumCard(
            icon: "hand.wave.fill",
            title: "Follow-through matters more than volume",
            body: "The strongest signals come from real attendance, thoughtful initiative, and reconnecting when there is a natural reason.",
            tint: .indigo
        ))

        return Array(cards.prefix(5))
    }

    private var ambientSignals: [AmbientHomeSignal] {
        var signals: [AmbientHomeSignal] = []

        if isEventActive {
            signals.append(AmbientHomeSignal(
                icon: "shield.lefthalf.filled",
                text: "Recommendations stay inside the context of this event unless you choose to take action.",
                tint: .blue
            ))
        } else {
            signals.append(AmbientHomeSignal(
                icon: "shield.lefthalf.filled",
                text: "Nearify becomes more aware through explicit presence, not background guessing.",
                tint: .blue
            ))
        }

        if attendeesService.attendeeCount >= 2 {
            signals.append(AmbientHomeSignal(
                icon: "dot.radiowaves.left.and.right",
                text: "This room has enough live overlap to support gentle introductions and better timing.",
                tint: .green
            ))
        }

        if let sharedTheme = strongestSharedTheme {
            signals.append(AmbientHomeSignal(
                icon: "sparkle.magnifyingglass",
                text: "People around you are loosely clustering around \(sharedTheme), based on public profile details.",
                tint: .orange
            ))
        }

        signals.append(AmbientHomeSignal(
            icon: "arrow.triangle.2.circlepath",
            text: "Home will change when the real-world context changes, not because there is an endless feed to consume.",
            tint: .purple
        ))

        return Array(signals.prefix(4))
    }

    private var strongestSharedTheme: String? {
        let themes = attendeesService.attendees.flatMap { attendee in
            (attendee.interests ?? []) + (attendee.skills ?? [])
        }
        let normalizedThemes = themes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedThemes.isEmpty else { return nil }

        let grouped = Dictionary(grouping: normalizedThemes) { $0.lowercased() }
        let strongest = grouped.max { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.value[0] > rhs.value[0]
            }
            return lhs.value.count < rhs.value.count
        }

        return strongest?.value.first
    }

    private func performDominantAction() {
        switch dominantAction.kind {
        case .scan:
            showScanner = true
        case .network:
            selectedTab = .network
        case .refresh:
            attendeesService.refresh()
        }
    }

    private var contextualGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.98, blue: 1.0),
                Color(red: 0.97, green: 0.95, blue: 1.0),
                Color(red: 0.96, green: 0.98, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var homeBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.secondarySystemBackground).opacity(0.55)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Home Surface Models

private struct DominantHomeAction {
    enum Kind {
        case scan
        case network
        case refresh
    }

    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let kind: Kind
}

private struct HomeMomentumCard: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
    let tint: Color
}

private struct AmbientHomeSignal: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let tint: Color
}

private struct MomentumCardView: View {
    let card: HomeMomentumCard

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(card.tint.opacity(0.13))
                Image(systemName: card.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(card.tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 7) {
                Text(card.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct InitialsBubble: View {
    let attendee: EventAttendee

    var body: some View {
        Group {
            if let avatarUrl = attendee.avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .clipShape(Circle())
    }

    private var initialsView: some View {
        Circle()
            .fill(Color.blue.opacity(0.14))
            .overlay(
                Text(attendee.initials)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
            )
    }
}

private extension EventAttendee {
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

#Preview {
    HomeView(selectedTab: .constant(.home))
}
