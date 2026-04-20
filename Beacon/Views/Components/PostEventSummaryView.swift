import SwiftUI

/// Renders the post-event summary inside the Home screen.
/// Shows: strongest connection, people to follow up with, missed opportunities.
/// Sections with no data are omitted entirely.
struct PostEventSummaryView: View {
    let summary: PostEventSummary
    let onMessage: (UUID) -> Void
    let onViewProfile: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR EVENT SUMMARY")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.cyan)
                    .tracking(0.8)

                if summary.totalPeopleMet > 0 {
                    Text("You met \(summary.totalPeopleMet) \(summary.totalPeopleMet == 1 ? "person" : "people") at \(summary.eventName)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            summarySection(
                title: "Event Snapshot",
                icon: "clock.badge.checkmark",
                color: .cyan
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    if let attended = summary.snapshot.attendedMinutes {
                        Text("Attended for \(attended) min")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Text("\(summary.snapshot.meaningfulPeopleCount) meaningful \(summary.snapshot.meaningfulPeopleCount == 1 ? "contact" : "contacts")")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                    Text(summary.snapshot.activityLine)
                        .font(.caption2)
                        .foregroundColor(.cyan.opacity(0.9))
                }
            }

            // ── Strongest Connection ──
            if let strongest = summary.strongestInteraction {
                summarySection(
                    title: "Strongest Connection",
                    icon: "bolt.fill",
                    color: .orange
                ) {
                    profileRow(strongest, accentColor: .orange, showActions: true)
                }
            }

            // ── Recent Connections ──
            if !summary.recentConnections.isEmpty {
                summarySection(
                    title: "New Connections",
                    icon: "link",
                    color: .green
                ) {
                    ForEach(summary.recentConnections) { profile in
                        profileRow(profile, accentColor: .green, showActions: true)
                    }
                }
            }

            // ── Key People ──
            if !summary.keyPeople.isEmpty {
                summarySection(
                    title: "Key People",
                    icon: "person.3.fill",
                    color: .mint
                ) {
                    ForEach(summary.keyPeople) { person in
                        keyPersonRow(person)
                    }
                }
            }

            // ── Missed Connections ──
            if !summary.missedConnections.isEmpty {
                summarySection(
                    title: "Missed Opportunities",
                    icon: "eye.slash",
                    color: .purple
                ) {
                    ForEach(summary.missedConnections) { profile in
                        profileRow(profile, accentColor: .purple, showActions: true)
                    }
                }
            }

            // ── Follow-Up Suggestions ──
            if !summary.followUpSuggestions.isEmpty {
                summarySection(
                    title: "Follow Up",
                    icon: "exclamationmark.bubble",
                    color: .yellow
                ) {
                    ForEach(summary.followUpSuggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }

            if !summary.narrativeWrapUp.isEmpty {
                summarySection(
                    title: "Wrap-Up",
                    icon: "text.quote",
                    color: .white
                ) {
                    Text(summary.narrativeWrapUp)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Section Container

    private func summarySection<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(color)
                Text(title.uppercased())
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
                    .tracking(0.8)
            }

            content()
        }
    }

    // MARK: - Profile Row

    private func profileRow(
        _ profile: ProfileSnapshot,
        accentColor: Color,
        showActions: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(
                    imageUrl: profile.avatarUrl,
                    name: profile.name,
                    size: 36,
                    placeholderColor: accentColor
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(profile.contextLine)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()
            }

            if showActions {
                HStack(spacing: 8) {
                    Button {
                        onMessage(profile.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left").font(.caption2)
                            Text("Message").font(.caption).fontWeight(.medium)
                        }
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.12))
                        .cornerRadius(6)
                    }

                    Button {
                        onViewProfile(profile.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person").font(.caption2)
                            Text("Profile").font(.caption).fontWeight(.medium)
                        }
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Suggestion Row

    private func suggestionRow(_ suggestion: FollowUpSuggestion) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                imageUrl: suggestion.targetProfile.avatarUrl,
                name: suggestion.targetProfile.name,
                size: 32,
                placeholderColor: suggestionColor(suggestion.type)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.targetProfile.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(suggestion.reason)
                    .font(.caption2)
                    .foregroundColor(suggestionColor(suggestion.type).opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                switch suggestion.type {
                case .message, .followUp:
                    onMessage(suggestion.targetProfile.id)
                case .meetNextTime:
                    onViewProfile(suggestion.targetProfile.id)
                }
            } label: {
                Text(suggestionActionLabel(suggestion.type))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(suggestionColor(suggestion.type))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(suggestionColor(suggestion.type).opacity(0.12))
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Key People Row

    private func keyPersonRow(_ person: KeyPerson) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                imageUrl: person.profile.avatarUrl,
                name: person.profile.name,
                size: 32,
                placeholderColor: keyTierColor(person.signalTier)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(person.profile.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(person.reason)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onViewProfile(person.profile.id)
            } label: {
                Text("Profile")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(keyTierColor(person.signalTier))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(keyTierColor(person.signalTier).opacity(0.12))
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Helpers

    private func suggestionColor(_ type: FollowUpSuggestion.SuggestionType) -> Color {
        switch type {
        case .followUp:     return .yellow
        case .message:      return .cyan
        case .meetNextTime: return .purple
        }
    }

    private func suggestionActionLabel(_ type: FollowUpSuggestion.SuggestionType) -> String {
        switch type {
        case .followUp:     return "Follow up"
        case .message:      return "Message"
        case .meetNextTime: return "Remember"
        }
    }

    private func keyTierColor(_ tier: KeyPerson.SignalTier) -> Color {
        switch tier {
        case .high: return .orange
        case .medium: return .mint
        case .low: return .gray
        }
    }
}
