import SwiftUI

/// State-aware decision surface for live event interaction.
/// Adapts layout based on EventCrowdState:
///   empty  → neutral message, no people
///   single → primary person only, no alternatives
///   pair   → primary + one alternative chip
///   group  → primary + up to 2 alternatives + scrollable attendee strip
struct DecisionSurfaceView: View {
    let surface: DecisionSurface
    let crowdState: EventCrowdState
    let liveAttendees: [EventAttendee]
    let onAction: (UUID, DecisionActionType) -> Void
    let onViewProfile: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch crowdState {
            case .empty:
                emptyState

            case .single:
                if let primary = surface.primary {
                    primaryArea(primary)
                }

            case .pair:
                if let primary = surface.primary {
                    primaryArea(primary)
                }
                if let alt = surface.alternatives.first {
                    alternativeChips([alt])
                }

            case .group:
                if let primary = surface.primary {
                    primaryArea(primary)
                }
                if !surface.alternatives.isEmpty {
                    alternativeChips(Array(surface.alternatives.prefix(2)))
                }
                if !liveAttendees.isEmpty {
                    attendeeStrip
                }
            }

            // Context line — always shown when people are present
            if crowdState != .empty {
                contextArea
            }
        }
    }

    // MARK: - Primary Area

    private func primaryArea(_ person: PersonSurface) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 16)

            // Tappable avatar → opens profile
            Button {
                onViewProfile(person.id)
            } label: {
                AvatarView(
                    imageUrl: person.avatarUrl,
                    name: person.name,
                    size: 112,
                    placeholderColor: strengthColor(person.strength)
                )
                .overlay(
                    Circle()
                        .stroke(strengthColor(person.strength).opacity(0.4), lineWidth: 3)
                )
            }

            Spacer().frame(height: 12)

            // Tappable name + proximity hint → opens profile
            Button {
                onViewProfile(person.id)
            } label: {
                VStack(spacing: 4) {
                    Text(firstName(person.name))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if let hint = person.proximityHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(strengthColor(person.strength).opacity(0.8))
                    }
                }
            }

            Spacer().frame(height: 16)

            // Signal tags
            if !person.signals.isEmpty {
                HStack(spacing: 8) {
                    ForEach(person.signals) { tag in
                        signalChip(tag)
                    }
                }
                .padding(.bottom, 16)
            }

            // CTA
            Button {
                onAction(person.id, person.action)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: person.action.icon)
                    Text(person.action.label)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(strengthColor(person.strength))
                .foregroundColor(.black)
                .cornerRadius(12)
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 20)
        }
    }

    // MARK: - Signal Chip

    private func signalChip(_ tag: SignalTag) -> some View {
        Text(tag.label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(signalColor(tag.type))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(signalColor(tag.type).opacity(0.12))
            .cornerRadius(8)
    }

    // MARK: - Alternative Chips

    private func alternativeChips(_ alts: [PersonSurface]) -> some View {
        HStack(spacing: 10) {
            ForEach(alts) { alt in
                Button {
                    onViewProfile(alt.id)
                } label: {
                    HStack(spacing: 8) {
                        AvatarView(
                            imageUrl: alt.avatarUrl,
                            name: alt.name,
                            size: 28,
                            placeholderColor: strengthColor(alt.strength)
                        )

                        Text(firstName(alt.name))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
    }

    // MARK: - Live Attendee Strip (group state only)

    private var attendeeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(liveAttendees) { attendee in
                    Button {
                        onViewProfile(attendee.id)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(
                                    imageUrl: attendee.avatarUrl,
                                    name: attendee.name,
                                    size: 40,
                                    placeholderColor: .cyan
                                )

                                if attendee.isHereNow {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                        .overlay(
                                            Circle().stroke(Color.black, lineWidth: 1.5)
                                        )
                                        .offset(x: 2, y: 2)
                                }
                            }

                            Text(firstName(attendee.name))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .frame(maxWidth: 48)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Context Area

    private var contextArea: some View {
        HStack(spacing: 12) {
            if surface.context.totalPeopleHere > 0 {
                contextPill(
                    icon: "person.2",
                    text: "\(surface.context.totalPeopleHere) here"
                )
            }
            if surface.context.metCount > 0 {
                contextPill(
                    icon: "checkmark.circle",
                    text: "\(surface.context.metCount) met"
                )
            }
            contextPill(
                icon: phaseIcon(surface.context.phase),
                text: surface.context.phase.rawValue
            )
        }
        .padding(.vertical, 8)
    }

    private func contextPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2)
        }
        .foregroundColor(.gray)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 32)
            Image(systemName: "person.wave.2")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.4))
            Text("You're the first one here 👋")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.7))
            Text("Others will appear as they arrive")
                .font(.caption)
                .foregroundColor(.gray)
            Spacer().frame(height: 32)
        }
    }

    // MARK: - Helpers

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    private func strengthColor(_ strength: Double) -> Color {
        if strength >= 0.8 { return .green }
        if strength >= 0.5 { return .cyan }
        if strength >= 0.3 { return .orange }
        return .gray
    }

    private func signalColor(_ type: SignalType) -> Color {
        switch type {
        case .proximity:    return .green
        case .duration:     return .orange
        case .recency:      return .cyan
        case .repeats:      return .purple
        case .relationship: return .yellow
        case .interest:     return .blue
        }
    }

    private func phaseIcon(_ phase: EventPhase) -> String {
        switch phase {
        case .early: return "sunrise"
        case .mid:   return "sun.max"
        case .late:  return "sunset"
        }
    }
}
