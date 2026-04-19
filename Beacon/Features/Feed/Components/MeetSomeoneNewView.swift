import SwiftUI

/// "Meet Someone New" section displayed below the event context card.
/// Shows 1–2 high-quality candidates with avatar, name, descriptor, and explanation.
struct MeetSomeoneNewView: View {
    let candidates: [MeetCandidate]
    let onFindAttendee: (UUID) -> Void
    let onViewProfile: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundColor(.cyan)
                Text("MEET SOMEONE NEW")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.cyan)
                    .tracking(1.2)
            }
            .padding(.horizontal)

            ForEach(candidates) { candidate in
                candidateCard(candidate)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Candidate Card

    private func candidateCard(_ candidate: MeetCandidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Avatar
                avatarView(candidate)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(candidate.descriptor)
                        .font(.caption)
                        .foregroundColor(.cyan.opacity(0.8))
                }

                Spacer()
            }

            // Explanation line
            Text(candidate.explanation)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.top, 6)

            // Actions — language adapts to presence state
            HStack(spacing: 12) {
                FeedActionButton(
                    title: UserPresenceStateResolver.shortMeetLabel,
                    icon: "hand.wave",
                    color: .cyan,
                    action: { onFindAttendee(candidate.id) }
                )

                FeedActionButton(
                    title: "View Profile",
                    icon: "person",
                    color: .white.opacity(0.7),
                    action: { onViewProfile(candidate.id) }
                )
            }
            .padding(.top, 10)
        }
        .feedCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Avatar

    private func avatarView(_ candidate: MeetCandidate) -> some View {
        Group {
            if let urlStr = candidate.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                    default:
                        initialsCircle(candidate.name)
                    }
                }
            } else {
                initialsCircle(candidate.name)
            }
        }
        .frame(width: 40, height: 40)
    }

    private func initialsCircle(_ name: String) -> some View {
        Circle()
            .fill(Color.cyan.opacity(0.2))
            .overlay(
                Text(initials(from: name))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan)
            )
    }

    private func initials(from name: String) -> String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
