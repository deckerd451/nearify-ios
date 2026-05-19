import SwiftUI

/// Compact horizontal card for displaying event attendee profile information
struct AttendeeCardView: View {
    let attendee: EventAttendee
    @State private var isVisible = false

    private var isRecentlySeen: Bool {
        attendee.presenceState == .stale
    }
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.15), .clear], startPoint: .bottom, endPoint: .top)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(attendee.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    if attendee.isActiveNow {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.cyan)
                    }
                }
                Text(attendee.detailSubtitleText)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.88))
                HStack(spacing: 10) {
                    Text(attendee.lastSeenText)
                    if isRecentlySeen { Text("Recently seen") }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
            }
            .padding(16)

            HStack {
                Spacer()
                Button("Connect") {}
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(14)
            }
        }
        .frame(height: 184)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .opacity(isRecentlySeen ? 0.82 : 1.0)
        .opacity(isVisible ? 1 : 0.0)
        .scaleEffect(isVisible ? 1 : 0.985)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isVisible = true
            }
        }
    }
    
    // MARK: - Avatar View
    
    private var heroImage: some View {
        Group {
            if let imageUrl = attendee.avatarUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        initialsPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
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
        Rectangle()
            .fill(VisualStyle.primaryAction.opacity(0.25))
            .overlay(
                Text(attendee.initials)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.7))
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
