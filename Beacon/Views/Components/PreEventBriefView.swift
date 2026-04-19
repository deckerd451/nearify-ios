import SwiftUI

/// Renders the Pre-Event Brief inside an expanded event card.
/// Shows: People Here Now, Likely Attendees, Conversation Starters, People to Meet.
/// Sections with no data are omitted entirely — no empty placeholders.
struct PreEventBriefView: View {
    let brief: PreEventBriefBuilder.Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── 1. PEOPLE HERE NOW ──
            if !brief.hereNow.isEmpty {
                briefSection(
                    title: "Here Now",
                    icon: "circle.fill",
                    iconColor: .green
                ) {
                    personRow(brief.hereNow)
                }
            }

            // ── 2. LIKELY ATTENDEES ──
            if !brief.likelyAttendees.isEmpty {
                briefSection(
                    title: "Likely Attendees",
                    icon: "person.crop.circle.badge.clock",
                    iconColor: .cyan
                ) {
                    personRow(brief.likelyAttendees)
                }
            }

            // ── 3. CONVERSATION STARTERS ──
            if !brief.conversationStarters.isEmpty {
                briefSection(
                    title: "Conversation Starters",
                    icon: "text.bubble",
                    iconColor: .orange
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(brief.conversationStarters.enumerated()), id: \.offset) { _, starter in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                                Text(starter)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            // ── 4. PEOPLE TO MEET ──
            if !brief.peopleToMeet.isEmpty {
                briefSection(
                    title: "People to Meet",
                    icon: "sparkles",
                    iconColor: .purple
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.elementSpacing) {
                        ForEach(brief.peopleToMeet) { person in
                            targetPersonRow(person)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section Container

    private func briefSection<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundColor(iconColor)
                Text(title.uppercased())
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(iconColor)
                    .tracking(0.8)
            }

            content()
        }
    }

    // MARK: - Person Row (avatar strip for Here Now / Likely Attendees)

    private func personRow(_ people: [PreEventBriefBuilder.PersonSnippet]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(people) { person in
                HStack(spacing: 10) {
                    AvatarView(
                        imageUrl: person.avatarUrl,
                        name: person.name,
                        size: 32,
                        placeholderColor: .cyan
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(person.contextLine)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }
        }
    }

    // MARK: - Target Person Row (People to Meet — with reason)

    private func targetPersonRow(_ person: PreEventBriefBuilder.PersonSnippet) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                imageUrl: person.avatarUrl,
                name: person.name,
                size: 36,
                placeholderColor: .purple
            )
            .overlay(
                Circle()
                    .stroke(Color.purple.opacity(0.3), lineWidth: 1.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(person.contextLine)
                    .font(.caption2)
                    .foregroundColor(.purple.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}
