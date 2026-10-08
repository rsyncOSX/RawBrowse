import AppKit
import Foundation

/// Keep cache policy changes and storage behind one isolation boundary.
/// The current SDK imports NSImage as Sendable; no unchecked cache wrapper or
/// additional synchronization contract is needed for callers.
actor MemoryImageCache {
    static let shared = MemoryImageCache()

    private let thumbnailCache = NSCache<NSString, CachedNSImage>()

    private init() {
        thumbnailCache.totalCostLimit = BrowserSettings.defaultGridCacheSizeMB * 1024 * 1024
        thumbnailCache.countLimit = 3000
    }

    func clear() {
        thumbnailCache.removeAllObjects()
    }

    func apply(settings: BrowserSettings) {
        thumbnailCache.totalCostLimit = max(0, settings.gridCacheSizeMB) * 1024 * 1024
    }

    func thumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
        let key = thumbnailCacheKey(for: url, maxPixelSize: maxPixelSize)
        return thumbnailCache.object(forKey: key)?.image
    }

    func storeThumbnail(_ image: NSImage, for url: URL, maxPixelSize: Int) {
        let key = thumbnailCacheKey(for: url, maxPixelSize: maxPixelSize)
        let cached = CachedNSImage(image: image)
        thumbnailCache.setObject(cached, forKey: key, cost: cached.cost)
    }

    private func thumbnailCacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(ImageSourceFingerprint.key(for: url))|\(max(maxPixelSize, 1))" as NSString
    }
}
