import SwiftUI

/// Feed card for a new message notification.
struct MessageCardView: View {
    let item: FeedItem
    var onReply: (() -> Void)?
    
    private var name: String {
        item.metadata?.actorName ?? "Someone"
    }
    
    private var preview: String {
        item.metadata?.messagePreview ?? ""
    }
    
    private var timeText: String {
        guard let date = item.createdAt else { return "" }
        return date.feedRelativeString
    }
    
    var body: some View {
        FeedCardContainer {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("New message from \(name)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    if !timeText.isEmpty {
                        Text(timeText)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
            }
            
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .padding(.top, 8)
            }
            
            HStack(spacing: 12) {
                feedActionButton("Reply", icon: "arrowshape.turn.up.left", color: .blue) {
                    onReply?()
                }
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Date Extension for Feed

extension Date {
    var feedRelativeString: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }
}
