import SwiftUI

struct PreEventBriefView: View {
    let brief: PreEventBriefBuilder.Brief
    let ctaTitle: String
    let onGoToEvent: () -> Void

    init(
        brief: PreEventBriefBuilder.Brief,
        ctaTitle: String = "Go to event",
        onGoToEvent: @escaping () -> Void
    ) {
        self.brief = brief
        self.ctaTitle = ctaTitle
        self.onGoToEvent = onGoToEvent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Event Brief")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.95))

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Goal")
                Text(brief.goalLine)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.95))
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Start with")
                if !brief.priorityPeople.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(brief.priorityPeople) { person in
                            personRow(person)
                        }
                    }
                } else {
                    Text(brief.isLive
                         ? "No strong matches here yet.\nWe'll keep updating this as attendees appear."
                         : "No strong matches yet.\nCheck in to see who’s here and get recommendations.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            if !brief.conversationStarters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Try this")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(brief.conversationStarters.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white.opacity(0.92))
                        }
                    }
                }
            }

            Button(action: onGoToEvent) {
                Text(ctaTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white.opacity(0.65))
            .padding(.bottom, -2)
    }

    private func personRow(_ person: PreEventBriefBuilder.PriorityPerson) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                imageUrl: person.avatarUrl,
                name: person.name,
                size: 36,
                placeholderColor: .blue
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    + Text(person.statusLabel.map { " — \($0)" } ?? "")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.7))

                Text(person.reason)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}
