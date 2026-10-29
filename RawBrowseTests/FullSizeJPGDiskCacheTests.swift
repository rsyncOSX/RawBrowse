import CoreGraphics
import Foundation
import ImageIO
@testable import RawBrowse
import Testing
import UniformTypeIdentifiers

@Suite("Full-size JPEG disk cache")
struct FullSizeJPGDiskCacheTests {
    @Test
    func `fallback JPEG is explicitly tagged upright`() throws {
        let image = try makeTestImage(width: 40, height: 20)
        let data = try #require(FullSizeJPGDiskCache.jpegData(from: image))
        let properties = try jpegProperties(from: data)

        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
    }

    @Test
    func `embedded JPEG cache applies source orientation`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = try makeTestImage(width: 40, height: 20)
        let sourceData = try makeJPEGData(from: image, orientation: 6)
        let embeddedData = try makeJPEGData(from: image)
        let sourceURL = root.appendingPathComponent("oriented.arw")
        try sourceData.write(to: sourceURL)

        let cache = FullSizeJPGDiskCache(
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
        )
        await cache.save(embeddedData, for: sourceURL)

        let loaded = await cache.load(for: sourceURL)

        #expect(loaded?.width == 20)
        #expect(loaded?.height == 40)
    }

    @Test
    func `source replacement invalidates cached preview`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = try makeTestImage(width: 40, height: 20)
        let sourceData = try makeJPEGData(from: image, orientation: 1)
        let cachedData = try #require(FullSizeJPGDiskCache.jpegData(from: image))
        let sourceURL = root.appendingPathComponent("replace.arw")
        try sourceData.write(to: sourceURL)

        let cache = FullSizeJPGDiskCache(
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
        )
        await cache.save(cachedData, for: sourceURL)
        #expect(await cache.load(for: sourceURL) != nil)

        try (sourceData + Data([0])).write(to: sourceURL, options: .atomic)

        #expect(await cache.load(for: sourceURL) == nil)
    }

    @Test
    func `developed RAW survives cache recreation independently of embedded JPEG`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.arw")
        try Data([1, 2, 3]).write(to: sourceURL)
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        let cache = FullSizeJPGDiskCache(cacheDirectory: directory)
        let embedded = try makeJPEGData(from: makeTestImage(width: 40, height: 20))
        let developed = try makeJPEGData(from: makeTestImage(width: 80, height: 60))
        await cache.save(embedded, for: sourceURL)
        await cache.save(developed, for: sourceURL, variant: .developedRAW)

        let reopened = FullSizeJPGDiskCache(cacheDirectory: directory)
        let rawImage = try #require(await reopened.load(for: sourceURL, variant: .developedRAW))
        let jpgImage = try #require(await reopened.load(for: sourceURL))
        #expect(rawImage.width == 80)
        #expect(rawImage.height == 60)
        #expect(jpgImage.width == 40)
        #expect(jpgImage.height == 20)
        try await reopened.clear()
        #expect(await reopened.load(for: sourceURL, variant: .developedRAW) == nil)
    }

    @Test
    func `thumbnail source metadata invalidates disk and memory entries`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: source)
        let image = try makeTestImage(width: 40, height: 20)
        let jpeg = try #require(ThumbnailDiskCache.jpegData(from: image))
        let cache = ThumbnailDiskCache(cacheDirectory: root.appendingPathComponent("cache"))
        await cache.save(jpeg, for: source, maxPixelSize: 200)
        let loaded = try #require(await cache.load(for: source, maxPixelSize: 200))
        await MemoryImageCache.shared.storeThumbnail(loaded, for: source, maxPixelSize: 200)
        // Keep size unchanged to exercise the modification-date component.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        #expect(await cache.load(for: source, maxPixelSize: 200) == nil)
        #expect(await MemoryImageCache.shared.thumbnail(for: source, maxPixelSize: 200) == nil)
        await cache.save(jpeg, for: source, maxPixelSize: 200)
        try Data([1, 2]).write(to: source)
        #expect(await cache.load(for: source, maxPixelSize: 200) == nil)
    }

    @Test
    func `In-place edits with preserved size and mtime invalidate every image cache`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("preserved.jpg")
        try Data([1, 2, 3]).write(to: source)
        let date = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let initial = ImageSourceFingerprint.key(for: source)
        let item = BrowserFileItem(url: source)
        let signature = BurstGroupSignature(files: [item], catalog: root)
        let image = try makeTestImage(width: 40, height: 20)
        let jpeg = try #require(ThumbnailDiskCache.jpegData(from: image))
        let thumbs = ThumbnailDiskCache(cacheDirectory: root.appendingPathComponent("thumbs"))
        let full = FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("full"))
        await thumbs.save(jpeg, for: source, maxPixelSize: 200)
        await full.save(jpeg, for: source)
        let loaded = try #require(await thumbs.load(for: source, maxPixelSize: 200))
        await MemoryImageCache.shared.storeThumbnail(loaded, for: source, maxPixelSize: 200)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data([4, 5, 6]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(attributes[.modificationDate] as? Date == date)
        #expect((attributes[.size] as? NSNumber)?.intValue == 3)
        #expect(ImageSourceFingerprint.key(for: source) != initial)
        #expect(BurstGroupSignature(files: [item], catalog: root) != signature)
        #expect(await thumbs.load(for: source, maxPixelSize: 200) == nil)
        #expect(await full.load(for: source) == nil)
        #expect(await MemoryImageCache.shared.thumbnail(for: source, maxPixelSize: 200) == nil)
    }

    @Test
    func `disk caches enforce byte limits including oversized entries`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.arw")
        try Data([1]).write(to: source)
        let thumbnail = ThumbnailDiskCache(cacheDirectory: root.appendingPathComponent("thumbs"), maximumBytes: 8)
        let full = FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("full"), maximumBytes: 8)
        await thumbnail.save(Data(repeating: 0, count: 9), for: source, maxPixelSize: 200)
        await full.save(Data(repeating: 0, count: 9), for: source)
        #expect(try await thumbnail.sizeInBytes() == 0)
        #expect(try await full.sizeInBytes() == 0)
    }

    @Test
    func `least recently used files are evicted and startup trims existing cache`() throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.jpg")
        let second = root.appendingPathComponent("second.jpg")
        let third = root.appendingPathComponent("third.jpg")
        try Data(repeating: 0, count: 4).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
        try Data(repeating: 0, count: 4).write(to: second)
        var policy = try DiskCachePolicy(directory: root, maximumBytes: 8)
        policy.recordHit(first)
        try Data(repeating: 0, count: 4).write(to: third)
        try policy.recordWrite(third, bytes: 4)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
        _ = try DiskCachePolicy(directory: root, maximumBytes: 4)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test
    func `preview resizing honors pixel limit and aspect ratio`() async throws {
        let image = try makeTestImage(width: 80, height: 40)
        let resized = try #require(await BrowserImageLoader.resizedPreview(image, maxPixelSize: 20))
        #expect(resized.width == 20)
        #expect(resized.height == 10)
        let unchanged = try #require(await BrowserImageLoader.resizedPreview(image, maxPixelSize: 100))
        #expect(unchanged.width == 80)
    }

    @Test
    func `cancelling one preview caller does not cancel another image`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.arw")
        let second = root.appendingPathComponent("second.arw")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let image = try makeTestImage(width: 40, height: 20)
        let gate = PreviewExtractionGate()
        let loader = BrowserImageLoader(fullSizeCache: FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache")), extractPreview: { _ in
            await gate.arriveAndWait()
            return Task.isCancelled ? nil : image
        })
        let firstRequest = Task { await loader.previewImage(for: first, maxPixelSize: 20) }
        await gate.waitForArrivals(1)
        let secondRequest = Task { await loader.previewImage(for: second, maxPixelSize: 10) }
        await gate.waitForArrivals(2)
        firstRequest.cancel()
        await gate.release()
        #expect(await firstRequest.value == nil)
        let result = try #require(await secondRequest.value)
        #expect(result.width == 10)
        #expect(result.height == 5)
    }

    @Test
    func `injected loader caches do not share disk entries`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.arw")
        try Data([1]).write(to: source)
        let image = try makeTestImage(width: 40, height: 20)
        let cacheA = FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache-a"))
        let cacheB = FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache-b"))
        let first = BrowserImageLoader(fullSizeCache: cacheA, extractPreview: { _ in image })
        let second = BrowserImageLoader(fullSizeCache: cacheB, extractPreview: { _ in nil })
        #expect(await first.previewImage(for: source, maxPixelSize: 20) != nil)
        #expect(await cacheA.load(for: source) != nil)
        #expect(await cacheB.load(for: source) == nil)
        #expect(await second.previewImage(for: source, maxPixelSize: 20) == nil)
        let reopened = BrowserImageLoader(fullSizeCache: cacheA, extractPreview: { _ in
            Issue.record("An isolated disk hit must not extract the source again")
            return nil
        })
        #expect(await reopened.previewImage(for: source, maxPixelSize: 20)?.width == 20)
    }

    @Test
    func `preview memory reuses final images and invalidates source and size changes`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.arw")
        try Data([1]).write(to: source)
        let image = try makeTestImage(width: 40, height: 20)
        let cache = FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache"))
        let loader = BrowserImageLoader(fullSizeCache: cache, extractPreview: { _ in image })
        let first = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        // Remove the disk entry so reuse can only come from memory.
        try await cache.clear()
        let again = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        #expect(first === again)
        let smaller = try #require(await loader.previewImage(for: source, maxPixelSize: 10))
        #expect(smaller.width == 10)
        #expect(smaller !== first)
        try Data([1, 2]).write(to: source, options: .atomic)
        let replaced = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        #expect(replaced !== first)
        var settings = BrowserSettings()
        settings.maxCachedExtractedJPGs = 0
        await loader.apply(settings: settings)
        let uncached = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        #expect(uncached !== replaced)
    }

    @Test
    func `standalone JPEG preview revisits use memory`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try makeJPEGData(from: makeTestImage(width: 40, height: 20), orientation: 6).write(to: source)
        let loader = BrowserImageLoader(fullSizeCache: FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache")))
        let first = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        #expect(first.width == 10)
        #expect(first.height == 20)
        let second = try #require(await loader.previewImage(for: source, maxPixelSize: 20))
        #expect(second === first)
    }

    @Test @MainActor
    func `JPG delivery precedes RAW support and sidecar restoration`() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.arw")
        try Data([1]).write(to: source)
        let image = try makeTestImage(width: 40, height: 20)
        let gate = PreviewExtractionGate()
        let loader = BrowserImageLoader(fullSizeCache: FullSizeJPGDiskCache(cacheDirectory: root.appendingPathComponent("cache")),
                                        extractPreview: { _ in image })
        let sidecarGate = PreviewExtractionGate()
        let session = RAW9EditingSession(load: { _ in
            await sidecarGate.arriveAndWait()
            return RAW9Adjustments(exposure: 1)
        })
        let zoom = ZoomModel(settings: SettingsModel(initialValues: BrowserSettings()), raw9: session,
                             imageLoader: loader, supportsRAW9: { _ in
                                 await gate.arriveAndWait()
                                 return true
                             })
        zoom.openZoom(for: BrowserFileItem(url: source))
        await gate.waitForArrivals(1)
        #expect(zoom.zoomImage != nil)
        #expect(zoom.isZoomExifInfoLoaded)
        #expect(zoom.raw9SupportedURL == nil)
        #expect(!session.hasRestored(source))
        await gate.release()
        await sidecarGate.waitForArrivals(1)
        #expect(zoom.zoomImage != nil)
        #expect(zoom.raw9SupportedURL == nil)
        // Closing while restoration is in flight must reject stale adjustments.
        zoom.closeZoom()
        await sidecarGate.release()
        #expect(zoom.zoomImage == nil)
        #expect(zoom.file == nil)
        #expect(zoom.raw9SupportedURL == nil)
    }

    @Test
    func `preview memory enforces LRU count byte and disabled limits`() throws {
        let small = try makeTestImage(width: 40, height: 20)
        let oversized = try makeTestImage(width: 1024, height: 1024)
        var settings = BrowserSettings()
        settings.maxCachedExtractedJPGs = 2
        settings.memoryCacheSizeMB = 1
        var cache = PreviewMemoryCache()
        cache.apply(settings: settings)
        cache.insert(small, for: "a")
        cache.insert(small, for: "b")
        #expect(cache.image(for: "a") != nil)
        cache.insert(small, for: "c")
        #expect(cache.image(for: "b") == nil)
        cache.insert(oversized, for: "large")
        #expect(cache.image(for: "large") == nil)
        #expect(cache.byteCount == small.bytesPerRow * small.height * 2)
        settings.maxCachedExtractedJPGs = 1
        cache.apply(settings: settings)
        #expect(cache.image(for: "a") == nil)
        #expect(cache.image(for: "c") != nil)
        settings.memoryCacheSizeMB = 0
        cache.apply(settings: settings)
        #expect(cache.byteCount == 0)
        cache.insert(small, for: "disabled")
        #expect(cache.image(for: "disabled") == nil)
        settings.memoryCacheSizeMB = 1
        cache.apply(settings: settings)
        cache.insert(small, for: "clear")
        cache.removeAll()
        #expect(cache.image(for: "clear") == nil)
        #expect(cache.byteCount == 0)
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawBrowseFullSizeCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeJPEGData(from image: CGImage, orientation: Int? = nil) throws -> Data {
        let mutableData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let properties: [CFString: Any] = if let orientation {
            [kCGImagePropertyOrientation: orientation]
        } else {
            [:]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    private func jpegProperties(from data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        )
    }
}

private actor PreviewExtractionGate {
    private var arrivals = 0
    private var workers: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func arriveAndWait() async {
        arrivals += 1
        let ready = observers.filter { $0.0 <= arrivals }
        observers.removeAll { $0.0 <= arrivals }
        for (_, observer) in ready {
            observer.resume()
        }
        await withCheckedContinuation { workers.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release() {
        let pending = workers
        workers.removeAll()
        for worker in pending {
            worker.resume()
        }
    }
}
