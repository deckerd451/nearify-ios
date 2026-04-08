import SwiftUI

/// Feed card for a BLE-derived encounter.
struct EncounterCardView: View {
    let item: FeedItem
    let onViewProfile: () -> Void
    let onConnect: () -> Void
    let onDismiss: () -> Void

    private var name: String {
        item.metadata?.actorName ?? "Someone nearby"
    }

    private var eventName: String? {
        item.metadata?.eventName
    }

    private var overlapText: String {
        guard let seconds = item.metadata?.overlapSeconds, seconds > 0 else {
            return "Brief encounter"
        }
        let minutes = seconds / 60
        if minutes < 1 { return "Nearby for \(seconds)s" }
        return "Nearby for \(minutes) min"
    }

    private var timeText: String {
        guard let date = item.createdAt else { return "" }
        return date.feedRelativeString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("You encountered \(name)")
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

            Text(overlapText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 8)

            HStack(spacing: 12) {
                FeedActionButton(title: "View Profile", icon: "person", color: .white.opacity(0.7), action: onViewProfile)
                FeedActionButton(title: "Connect", icon: "person.badge.plus", color: .green, action: onConnect)
                FeedActionButton(title: "Dismiss", icon: "xmark", color: .gray, action: onDismiss)
            }
            .padding(.top, 12)
        }
        .feedCard()
    }
}
