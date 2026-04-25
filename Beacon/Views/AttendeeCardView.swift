import SwiftUI

/// Compact horizontal card for displaying event attendee profile information
struct AttendeeCardView: View {
    let attendee: EventAttendee
    @State private var isVisible = false

    private var isRecentlySeen: Bool {
        attendee.presenceState == .stale
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            avatarView
                .frame(width: 44, height: 44)
            
            // Profile info
            VStack(alignment: .leading, spacing: 4) {
                // Name
                Text(attendee.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(isRecentlySeen ? VisualStyle.secondaryText : .white)
                
                // Subtitle from bio/skills/interests
                Text(attendee.detailSubtitleText)
                    .font(.caption)
                    .foregroundColor(VisualStyle.secondaryText)
                    .lineLimit(1)
                
                // Tags (if available)
                if !attendee.topTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attendee.topTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(VisualStyle.intelligence.opacity(0.18))
                                )
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                }
            }
            
            Spacer()
            
            // Status indicator
            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(attendee.isActiveNow ? VisualStyle.live : VisualStyle.primaryAction.opacity(0.8))
                    .frame(width: 8, height: 8)

                if isRecentlySeen {
                    Text("Recently seen")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(VisualStyle.tertiaryText)
                }
                
                Text(attendee.lastSeenText)
                    .font(.system(size: 10))
                    .foregroundColor(VisualStyle.tertiaryText)
            }
        }
        .padding(12)
        .elevatedCard(accent: attendee.isActiveNow ? VisualStyle.live : VisualStyle.primaryAction, glow: 0.10)
        .opacity(isRecentlySeen ? 0.82 : 1.0)
        .opacity(isVisible ? 1 : 0.0)
        .offset(y: isVisible ? 0 : 6)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isVisible = true
            }
        }
    }
    
    // MARK: - Avatar View
    
    private var avatarView: some View {
        Group {
            if let imageUrl = attendee.avatarUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 44, height: 44)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                    case .failure:
                        initialsPlaceholder
                    @unknown default:
                        initialsPlaceholder
                    }
                }
            } else {
                initialsPlaceholder
            }
        }
    }
    
    private var initialsPlaceholder: some View {
        Circle()
            .fill(VisualStyle.primaryAction.opacity(0.25))
            .overlay(
                Text(attendee.initials)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            )
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        // Full profile
        AttendeeCardView(attendee: EventAttendee(
            id: UUID(),
            name: "Doug Hamilton",
            avatarUrl: nil,
            bio: "Human centered design • AI • Founder",
            skills: ["Swift", "Product Design", "AI"],
            interests: ["Technology", "Design", "Innovation"],
            energy: 0.8,
            lastSeen: Date()
        ))
        
        // No bio, has skills
        AttendeeCardView(attendee: EventAttendee(
            id: UUID(),
            name: "Jane Smith",
            avatarUrl: nil,
            bio: nil,
            skills: ["React", "TypeScript", "Node.js"],
            interests: nil,
            energy: 0.6,
            lastSeen: Date().addingTimeInterval(-45)
        ))
        
        // No bio, has interests
        AttendeeCardView(attendee: EventAttendee(
            id: UUID(),
            name: "Alex Chen",
            avatarUrl: nil,
            bio: nil,
            skills: nil,
            interests: ["Music", "Art", "Coffee"],
            energy: 0.5,
            lastSeen: Date().addingTimeInterval(-120)
        ))
        
        // Minimal data
        AttendeeCardView(attendee: EventAttendee(
            id: UUID(),
            name: "Sam Wilson",
            avatarUrl: nil,
            bio: nil,
            skills: nil,
            interests: nil,
            energy: 0.3,
            lastSeen: Date().addingTimeInterval(-300)
        ))
    }
    .padding()
}
