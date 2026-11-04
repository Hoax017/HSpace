import Foundation
import CoreGraphics

// Private concern: LRU cache (NSCache wrapper) + staleness-proof cache keys.

/// NSCache accepts only classes; CGImage is a struct-like CF type, so it is held in a reference box.
final class ThumbnailBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// LRU thumbnail cache: countLimit=512 (several times the visible window of a scrolling list, enough to reuse yet bounded).
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, ThumbnailBox>()

    init() {
        cache.countLimit = 512
    }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func store(_ image: CGImage, forKey key: String) {
        cache.setObject(ThumbnailBox(image), forKey: key as NSString)
    }
}

/// Cache key = path + size + scale + mtime: a changed mtime changes the key, and old images age out of the LRU naturally (no staleness).
func cacheKey(url: URL, size: CGFloat, scale: CGFloat) -> String {
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSince1970 ?? 0
    return "\(url.path)|\(Int(size))|\(Int(scale))|\(mtime)"
}
