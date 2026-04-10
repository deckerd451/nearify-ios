import SwiftUI
import UIKit

/// Thumbnail avatar for Home surface cards.
/// Uses ThumbnailCache for bounded, downsampled image loading.
/// Falls back to initials circle when no image is available.
struct SurfaceThumbnailView: View {
    let avatarUrl: String?
    let name: String
    var accentColor: Color = .blue

    private static let size: CGFloat = 36

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
                initialsCircle
            }
        }
        .frame(width: Self.size, height: Self.size)
        .task(id: avatarUrl) {
            await loadThumbnail()
        }
    }

    private var initialsCircle: some View {
        Circle()
            .fill(accentColor.opacity(0.2))
            .overlay(
                Text(initials)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(accentColor)
            )
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

        // Check cache synchronously first
        if let cached = ThumbnailCache.shared.thumbnail(for: urlString) {
            thumbnail = cached
            return
        }

        // Load async (downsampled + cached)
        if let loaded = await ThumbnailCache.shared.loadThumbnail(for: urlString) {
            thumbnail = loaded
        }
    }
}
