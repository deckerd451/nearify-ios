import SwiftUI

/// Feed card for a confirmed connection.
struct ConnectionCardView: View {
    let item: FeedItem
    var onMessage: (() -> Void)?
    var onViewProfile: (() -> Void)?
    
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
        FeedCardContainer {
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
                feedActionButton("Message", icon: "bubble.left", color: .blue) {
                    onMessage?()
                }
                feedActionButton("View Profile", icon: "person", color: .white.opacity(0.7)) {
                    onViewProfile?()
                }
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Feed Action Button

func feedActionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }
    .buttonStyle(.plain)
}
