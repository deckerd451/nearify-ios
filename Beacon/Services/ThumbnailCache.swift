import UIKit

/// Bounded in-memory thumbnail cache for Home surface cards.
/// Uses NSCache with count + cost limits for automatic LRU eviction.
/// Separate from full-resolution profile images loaded elsewhere.
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session = URLSession(configuration: .default)

    /// Thumbnail render size (points). Images are downsampled to this before caching.
    static let thumbnailSize: CGFloat = 40

    private init() {
        cache.countLimit = 80              // max 80 thumbnails
        cache.totalCostLimit = 8_000_000   // ~8 MB
    }

    // MARK: - Public API

    /// Returns a cached thumbnail or nil. Non-blocking.
    func thumbnail(for urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    /// Loads, downsamples, and caches a thumbnail. Safe to call from any actor.
    func loadThumbnail(for urlString: String) async -> UIImage? {
        // Check cache first
        if let cached = cache.object(forKey: urlString as NSString) {
            return cached
        }

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let thumb = downsample(data: data, to: Self.thumbnailSize) else { return nil }

            let cost = thumb.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(thumb, forKey: urlString as NSString, cost: cost)

            return thumb
        } catch {
            #if DEBUG
            print("[ThumbCache] ⚠️ Failed to load: \(urlString.prefix(60)) — \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Evicts all cached thumbnails.
    func clear() {
        cache.removeAllObjects()
    }

    // MARK: - Downsampling

    /// Downsamples raw image data to a target point size using ImageIO.
    /// This avoids decoding the full image into memory.
    private func downsample(data: Data, to pointSize: CGFloat) -> UIImage? {
        let scale = UIScreen.main.scale
        let pixelSize = pointSize * scale

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
