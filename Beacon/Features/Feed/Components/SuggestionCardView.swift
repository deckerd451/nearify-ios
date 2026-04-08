import SwiftUI

/// Feed card for a follow-up suggestion.
struct SuggestionCardView: View {
    let item: FeedItem
    let onConnect: () -> Void
    let onMessage: () -> Void

    private var name: String {
        item.metadata?.actorName ?? "Someone"
    }

    private var reason: String {
        item.metadata?.suggestionReason ?? "You may want to connect"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.purple.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundColor(.purple)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Follow-up opportunity")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(name)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
            }

            Text(reason)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 8)

            HStack(spacing: 12) {
                FeedActionButton(title: "Connect", icon: "person.badge.plus", color: .purple, action: onConnect)
                FeedActionButton(title: "Message", icon: "bubble.left", color: .blue, action: onMessage)
            }
            .padding(.top, 12)
        }
        .feedCard()
    }
}
