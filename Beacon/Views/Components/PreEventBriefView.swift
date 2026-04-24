import SwiftUI

struct PreEventBriefView: View {
    let brief: PreEventBriefBuilder.Brief
    let onGoToEvent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Event Brief")
                .font(.title3)
                .fontWeight(.semibold)

            sectionTitle("Today’s goal")
            Text(brief.goalLine)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if !brief.priorityPeople.isEmpty {
                sectionTitle("Start with")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(brief.priorityPeople) { person in
                        personRow(person)
                    }
                }
            }

            sectionTitle("Why")
            Text(brief.whyLine)
                .font(.footnote)
                .foregroundColor(.secondary)

            if !brief.conversationStarters.isEmpty {
                sectionTitle("Try this")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(brief.conversationStarters.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let missed = brief.missedOpportunityLine {
                Text(missed)
                    .font(.footnote)
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.top, 2)
            }

            Button(action: onGoToEvent) {
                Text("Go to event")
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
            .foregroundColor(.secondary)
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
                    .lineLimit(1)

                Text(person.reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}
