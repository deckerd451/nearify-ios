import SwiftUI


private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print(message())
#endif
}

/// Renders the post-event summary inside the Home screen.
/// Shows: strongest connection, people to follow up with, missed opportunities.
/// Sections with no data are omitted entirely.
struct PostEventSummaryView: View {
    let summary: PostEventSummary
    let onMessage: (UUID) -> Void
    let onViewProfile: (UUID) -> Void
    let onRememberFollowUp: ((UUID) -> Void)?

    @State private var rememberedProfileIds: Set<UUID> = []
    @State private var showFollowUpToast = false

    init(
        summary: PostEventSummary,
        onMessage: @escaping (UUID) -> Void,
        onViewProfile: @escaping (UUID) -> Void,
        onRememberFollowUp: ((UUID) -> Void)? = nil
    ) {
        self.summary = summary
        self.onMessage = onMessage
        self.onViewProfile = onViewProfile
        self.onRememberFollowUp = onRememberFollowUp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Evening summary header — no mechanical labels
            VStack(alignment: .leading, spacing: 6) {
                if summary.totalPeopleMet > 0 {
                    Text("\(summary.totalPeopleMet) \(summary.totalPeopleMet == 1 ? "person" : "people") at \(summary.eventName).")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.9))
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let attended = summary.snapshot.attendedMinutes {
                        Text("\(attended) min there.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    Text(summary.snapshot.activityLine)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            // ── Strongest moment ──
            if let strongest = summary.strongestInteraction {
                summarySection(
                    title: "Strongest moment",
                    color: .orange
                ) {
                    profileRow(strongest, accentColor: .orange, showActions: true)
                }
            }

            // ── Also connected ──
            if !summary.recentConnections.isEmpty {
                summarySection(
                    title: "You also connected",
                    color: .green
                ) {
                    ForEach(summary.recentConnections) { profile in
                        profileRow(profile, accentColor: .green, showActions: true)
                    }
                }
            }

            // ── Time spent nearby ──
            if !summary.keyPeople.isEmpty {
                summarySection(
                    title: "Time spent nearby",
                    color: .mint
                ) {
                    ForEach(summary.keyPeople) { person in
                        keyPersonRow(person)
                    }
                }
            }

            // ── Also in the room ──
            if !summary.missedConnections.isEmpty {
                summarySection(
                    title: "Also in the room",
                    color: .purple
                ) {
                    ForEach(summary.missedConnections) { profile in
                        profileRow(profile, accentColor: .purple, showActions: true)
                    }
                }
            }

            // ── Worth continuing ──
            if !summary.followUpSuggestions.isEmpty {
                summarySection(
                    title: "Worth continuing",
                    color: .yellow
                ) {
                    ForEach(summary.followUpSuggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }

            if !summary.narrativeWrapUp.isEmpty {
                Text(summary.narrativeWrapUp)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if showFollowUpToast {
                Text("Saved to orbit")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.yellow.opacity(0.95))
                    )
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFollowUpToast)
    }

    // MARK: - Section Container

    private func summarySection<Content: View>(
        title: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(color.opacity(0.7))

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
                        debugLog("[EventRecap] profile tapped: \(profile.id)")
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

    @ViewBuilder
    private func suggestionRow(_ suggestion: FollowUpSuggestion) -> some View {
        let isRemembered = rememberedProfileIds.contains(suggestion.targetProfile.id)

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
                    rememberedProfileIds.insert(suggestion.targetProfile.id)
                    onRememberFollowUp?(suggestion.targetProfile.id)
                    debugLog("[EventRecap] follow-up remembered: \(suggestion.targetProfile.id)")
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFollowUpToast = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showFollowUpToast = false
                            }
                        }
                    }
                }
            } label: {
                Text(suggestionActionLabel(suggestion.type, isRemembered: isRemembered))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(isRemembered ? .green : suggestionColor(suggestion.type))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((isRemembered ? Color.green : suggestionColor(suggestion.type)).opacity(0.12))
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
                debugLog("[EventRecap] profile tapped: \(person.profile.id)")
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

    private func suggestionActionLabel(_ type: FollowUpSuggestion.SuggestionType, isRemembered: Bool = false) -> String {
        switch type {
        case .followUp:     return "Pick up the thread"
        case .message:      return "Say hello"
        case .meetNextTime: return isRemembered ? "Saved" : "Save for later"
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
