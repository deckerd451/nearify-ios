import SwiftUI

/// Feed card for a confirmed connection.
struct ConnectionCardView: View {
    let item: FeedItem
    let onMessage: () -> Void
    let onViewProfile: () -> Void

    private var name: String {
        item.metadata?.actorName ?? "Someone"
    }

    private var eventName: String? {
        item.metadata?.eventName
    }

    private var sharedInterests: [String] {
        item.metadata?.sharedInterests ?? []
    }

    private var timeText: String {
        guard let date = item.createdAt else { return "" }
        return date.feedRelativeString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon + Title
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("You connected with \(name)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        if let event = eventName {
                            Text(event)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        if !timeText.isEmpty {
                            Text("• \(timeText)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }

                Spacer()
            }

            // Shared interests
            if !sharedInterests.isEmpty {
                Text("Shared interests: \(sharedInterests.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 8)
            }

            // Actions
            HStack(spacing: 12) {
                FeedActionButton(title: "Message", icon: "bubble.left", color: .blue, action: onMessage)
                FeedActionButton(title: "View Profile", icon: "person", color: .white.opacity(0.7), action: onViewProfile)
            }
            .padding(.top, 12)
        }
        .feedCard()
    }
}
