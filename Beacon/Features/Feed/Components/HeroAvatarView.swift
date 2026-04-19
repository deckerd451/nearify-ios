import SwiftUI
import UIKit

/// Centered avatar rendered at the top of the Home hero block when a
/// featured arrival person is surfaced. Larger than the card-level
/// thumbnail (64pt vs 36pt) but smaller than a full profile hero.
///
/// Uses ThumbnailCache for bounded, downsampled image loading.
/// Falls back to accent-colored initials when no image is available.
struct HeroAvatarView: View {
    let avatarUrl: String?
    let name: String
    var accentColor: Color = .orange

    private static let size: CGFloat = 64

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(accentColor.opacity(0.2))
                    .overlay(
                        Text(initials)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(accentColor)
                    )
            }
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(
            Circle()
                .stroke(accentColor.opacity(0.3), lineWidth: 2)
        )
        .task(id: avatarUrl) {
            await loadThumbnail()
        }
    }

    private var initials: String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func loadThumbnail() async {
        guard let urlString = avatarUrl, !urlString.isEmpty else { return }
        if let cached = ThumbnailCache.shared.thumbnail(for: urlString) {
            thumbnail = cached
            return
        }
        if let loaded = await ThumbnailCache.shared.loadThumbnail(for: urlString) {
            thumbnail = loaded
        }
    }
}
