import CoreGraphics
import Foundation

/// Owned by BrowserImageLoader. Retains final display images, including their size variant.
nonisolated struct PreviewMemoryCache {
    private struct Entry {
        let key: String
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
    }

    private var entries: [Entry] = []
    private(set) var byteCount = 0
    private var byteLimit = BrowserSettings.defaultMemoryCacheSizeMB * 1024 * 1024
    private var countLimit = BrowserSettings.defaultMaxCachedExtractedJPGs

    mutating func apply(settings: BrowserSettings) {
        byteLimit = max(0, min(settings.memoryCacheSizeMB, BrowserSettings.defaultMemoryCacheSizeMB)) * 1024 * 1024
        countLimit = max(0, min(settings.maxCachedExtractedJPGs, BrowserSettings.defaultMaxCachedExtractedJPGs))
        trim()
    }

    mutating func image(for key: String) -> CGImage? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: String) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            byteCount -= entries.remove(at: index).cost
        }
        let entry = Entry(key: key, image: image)
        guard countLimit > 0, entry.cost <= byteLimit else { return }
        entries.append(entry)
        byteCount += entry.cost
        trim()
    }

    mutating func removeAll() {
        entries.removeAll()
        byteCount = 0
    }

    private mutating func trim() {
        while !entries.isEmpty, entries.count > countLimit || byteCount > byteLimit {
            byteCount -= entries.removeFirst().cost
        }
    }
}
