import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// Construction factory + entry point (Axiom 2: the LRU cache is instance-private, not a global singleton).
/// NSCache is itself thread-safe and nothing else is mutable, so @unchecked Sendable holds.
public final class IconThumb: IconThumbnailing, @unchecked Sendable {
    private let cache = ThumbnailCache()
    private let scale: CGFloat = 2   // generated for Retina; the contract documents pixels <= size*scale

    public init() {}

    public func thumbnail(for url: URL, size: CGFloat) async -> CGImage? {
        if Task.isCancelled { return nil }

        // The key includes mtime: old thumbnails expire automatically after a file changes (no staleness), no explicit invalidate needed.
        let key = cacheKey(url: url, size: size, scale: scale)
        if let hit = cache.image(forKey: key) { return hit }

        guard let image = await generateThumbnail(url: url, size: size, scale: scale) else {
            return nil
        }
        cache.store(image, forKey: key)
        return image
    }
}
