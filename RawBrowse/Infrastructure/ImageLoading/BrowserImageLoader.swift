import AppKit
import ImageIO
import RawParserKit

actor BrowserImageLoader {
    static let shared = BrowserImageLoader()

    private struct ImageTaskKey: Hashable {
        // Used by synthesized Hashable and Equatable to identify shared image tasks.
        // periphery:ignore
        let url: URL
        // Used by synthesized Hashable and Equatable to identify shared image tasks.
        // periphery:ignore
        let maxPixelSize: Int
    }

    private var thumbnailTaskIDs: [ImageTaskKey: UUID] = [:]
    private var thumbnailTasks: [ImageTaskKey: Task<NSImage?, Never>] = [:]
    private var extractedJPGTasks: [URL: Task<CGImage?, Never>] = [:]
    private var extractedJPGTaskIDs: [URL: UUID] = [:]

    private var developedTasks: [URL: Task<CGImage, Error>] = [:]

    private var isClearingCaches = false
    private var cacheGeneration = 0
    private var previewMemoryCache = PreviewMemoryCache()

    private let extractPreview: @Sendable (URL) async -> CGImage?

    init(fullSizeCache: FullSizeJPGDiskCache = .shared, extractPreview: @escaping @Sendable (URL) async -> CGImage? = {
        await RawParserKit.RawImageLoader.shared.previewImage(for: $0)
    }) {
        self.fullSizeCache = fullSizeCache
        self.extractPreview = extractPreview
    }

    private let fullSizeCache: FullSizeJPGDiskCache

    func apply(settings: BrowserSettings) {
        previewMemoryCache.apply(settings: settings)
    }

    func discoverFolders(at folderURL: URL) async -> [BrowserFolderItem] {
        let diagnostic = BrowserPerformance.begin("discovery.folders", folderURL)
        defer { diagnostic?.end(Task.isCancelled ? "cancelled" : "finished") }
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        return await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
            ) else { return [] }

            return children.compactMap { url -> BrowserFolderItem? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isHidden != true else { return nil }
                return Self.folderItem(at: url, supportsRAW9: nil)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    func folderItem(at folderURL: URL) async -> BrowserFolderItem {
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        return await Task.detached(priority: .utility) {
            Self.folderItem(at: folderURL, supportsRAW9: nil)
        }.value
    }

    /// Run decoder probes separately so folder discovery never waits for compatibility.
    nonisolated func hasRAW9Files(at folderURL: URL) async -> Bool {
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        let worker = Task.detached(priority: .background) {
            Self.folderItem(at: folderURL, supportsRAW9: { RAW9Support.supportsDecoder(for: $0) }).hasRAW9Files
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func discoverSupportedFiles(at folderURL: URL) async throws -> [BrowserFileItem] {
        let diagnostic = BrowserPerformance.begin("discovery.files", folderURL)
        defer { diagnostic?.end(Task.isCancelled ? "cancelled" : "finished") }
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        return try await Task.detached(priority: .utility) {
            let supported = RawFormatRegistry.allExtensions.union(SupportedFileType.renderedImageExtensions)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
            let children: [URL] = try {
                let interval = BrowserPerformance.begin("discovery.files.enumerate", folderURL)
                defer { interval?.end() }
                return try FileManager.default.contentsOfDirectory(
                    at: folderURL, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            }()

            let filtering = BrowserPerformance.begin("discovery.files.filterAndMetadata", folderURL)
            let files = children.compactMap { url -> BrowserFileItem? in
                guard supported.contains(url.pathExtension.lowercased()) else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true, values?.isHidden != true else { return nil }
                return BrowserFileItem(url: url)
            }
            filtering?.end()
            let sorting = BrowserPerformance.begin("discovery.files.sort", folderURL)
            let sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            sorting?.end()
            return sorted
        }.value
    }

    func thumbnail(for url: URL, targetSize: Int = 200) async -> NSImage? {
        let diagnostic = BrowserPerformance.begin("thumbnail.total", url, details: ["target_pixels": String(targetSize)])
        defer { diagnostic?.end(Task.isCancelled ? "cancelled" : "finished") }
        let access = await CatalogAccess.shared.lease(for: url)
        guard !isClearingCaches else { return nil }
        let boundedTargetSize = max(targetSize, 1)
        let taskKey = ImageTaskKey(url: url, maxPixelSize: boundedTargetSize)

        if let cached = await MemoryImageCache.shared.thumbnail(for: url, maxPixelSize: boundedTargetSize) {
            return cached
        }

        guard !isClearingCaches else { return nil }
        if let existing = thumbnailTasks[taskKey] {
            BrowserPerformance.event("thumbnail.sharedWait", fields: ["path": url.path,
                "target_pixels": boundedTargetSize, "active_thumbnail_tasks": thumbnailTasks.count])
            return await existing.value
        }

        let taskID = UUID()
        let generation = cacheGeneration
        let task = Task<NSImage?, Never>(priority: .utility) {
            defer { withExtendedLifetime(access) {} }
            guard !Task.isCancelled else { return nil }
            let diskTiming = BrowserPerformance.begin("thumbnail.diskLookup", url)
            let diskImage = await ThumbnailDiskCache.shared.load(
                for: url,
                maxPixelSize: boundedTargetSize,
            )
            diskTiming?.end(diskImage == nil ? "miss" : "hit")
            if let diskImage {
                guard !Task.isCancelled, generation == cacheGeneration else { return nil }
                await MemoryImageCache.shared.storeThumbnail(
                    diskImage,
                    for: url,
                    maxPixelSize: boundedTargetSize,
                )
                return diskImage
            }

            let parserTiming = BrowserPerformance.begin("thumbnail.parser", url, details: ["target_pixels": String(boundedTargetSize)])
            let parsedImage = await RawParserKit.RawImageLoader.shared.thumbnail(
                for: url,
                maxPixelSize: boundedTargetSize,
            )
            parserTiming?.end(parsedImage == nil ? "failed" : "image")
            guard let image = parsedImage, !Task.isCancelled else { return nil }

            guard generation == cacheGeneration else { return nil }
            await MemoryImageCache.shared.storeThumbnail(image, for: url, maxPixelSize: boundedTargetSize)
            let saveTiming = BrowserPerformance.begin("thumbnail.encodeAndSave", url)
            defer { saveTiming?.end() }
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let jpegData = ThumbnailDiskCache.jpegData(from: cgImage) {
                await ThumbnailDiskCache.shared.save(
                    jpegData,
                    for: url,
                    maxPixelSize: boundedTargetSize,
                )
            }
            return image
        }

        thumbnailTasks[taskKey] = task
        thumbnailTaskIDs[taskKey] = taskID
        BrowserPerformance.event("thumbnail.taskStarted", fields: ["path": url.path,
            "task_id": taskID.uuidString, "target_pixels": boundedTargetSize,
            "active_thumbnail_tasks": thumbnailTasks.count, "active_preview_tasks": extractedJPGTasks.count])
        let image = await task.value
        if thumbnailTaskIDs[taskKey] == taskID {
            thumbnailTasks[taskKey] = nil
            thumbnailTaskIDs[taskKey] = nil
        }
        BrowserPerformance.event("thumbnail.taskFinished", fields: ["path": url.path,
            "task_id": taskID.uuidString, "active_thumbnail_tasks": thumbnailTasks.count,
            "cancelled_waiter": Task.isCancelled])
        return image
    }

    func previewImage(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, !isClearingCaches else { return nil }
        let key = "\(ImageSourceFingerprint.key(for: url))|\(max(1, maxPixelSize))"
        if let image = previewMemoryCache.image(for: key) {
            BrowserPerformance.event("preview.memoryHit", fields: ["path": url.path, "target_pixels": maxPixelSize])
            return image
        }
        let generation = cacheGeneration
        guard let image = await fullSizePreview(for: url), !Task.isCancelled,
              generation == cacheGeneration else { return nil }
        let resize = BrowserPerformance.begin("preview.resize", url, details: ["target_pixels": String(maxPixelSize)])
        defer { resize?.end(Task.isCancelled ? "cancelled" : "finished") }
        let resized = await Self.resizedPreview(image, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled, generation == cacheGeneration, !isClearingCaches else { return nil }
        // Do not retain an image if its source changed while it was loading.
        if let resized, key == "\(ImageSourceFingerprint.key(for: url))|\(max(1, maxPixelSize))" {
            previewMemoryCache.insert(resized, for: key)
        }
        return resized
    }

    private func fullSizePreview(for url: URL) async -> CGImage? {
        let diagnostic = BrowserPerformance.begin("preview.total", url)
        defer { diagnostic?.end(Task.isCancelled ? "cancelled" : "finished") }
        let access = await CatalogAccess.shared.lease(for: url)
        guard !isClearingCaches else { return nil }
        if let existing = extractedJPGTasks[url] {
            return await existing.value
        }

        let taskID = UUID()
        let task = Task<CGImage?, Never>(priority: .userInitiated) {
            defer { withExtendedLifetime(access) {} }
            guard !Task.isCancelled else { return nil }

            if SupportedFileType.isRenderedImage(url) {
                let timing = BrowserPerformance.begin("preview.originalImage", url)
                let image = await Self.loadCGImage(from: url)
                timing?.end(image == nil ? "failed" : "image")
                return image
            }

            let lookup = BrowserPerformance.begin("preview.diskLookup", url)
            let cached = await fullSizeCache.load(for: url)
            lookup?.end(cached == nil ? "miss" : "hit")
            if let cached {
                guard !Task.isCancelled else { return nil }
                return cached
            }

            let extractionTiming = BrowserPerformance.begin("preview.extract", url)
            let extracted = await extractPreview(url)
            extractionTiming?.end(extracted == nil ? "failed" : "image")
            guard !Task.isCancelled else { return nil }

            if let extracted {
                let persistence = BrowserPerformance.begin("preview.sourceJPEGAndSave", url)
                defer { persistence?.end(Task.isCancelled ? "cancelled" : "finished") }
                let sourceJPEGData = await Self.embeddedPreviewJPEGData(
                    for: url,
                    matchingPixelWidth: extracted.width,
                    height: extracted.height,
                )
                guard !Task.isCancelled else { return nil }

                if let jpegData = sourceJPEGData ?? FullSizeJPGDiskCache.jpegData(from: extracted) {
                    await fullSizeCache.save(jpegData, for: url)
                }
            }

            return extracted
        }

        extractedJPGTasks[url] = task
        extractedJPGTaskIDs[url] = taskID
        BrowserPerformance.event("preview.taskStarted", fields: ["path": url.path,
            "task_id": taskID.uuidString, "active_preview_tasks": extractedJPGTasks.count])
        let image = await task.value
        if extractedJPGTaskIDs[url] == taskID {
            extractedJPGTasks[url] = nil
            extractedJPGTaskIDs[url] = nil
        }
        BrowserPerformance.event("preview.taskFinished", fields: ["path": url.path,
            "task_id": taskID.uuidString, "active_preview_tasks": extractedJPGTasks.count])
        return image
    }

    func developedPreview(for url: URL) async throws -> CGImage {
        let access = await CatalogAccess.shared.lease(for: url)
        guard !isClearingCaches else { throw CancellationError() }
        try Task.checkCancellation()
        if let existing = developedTasks[url] {
            let image = try await existing.value
            try Task.checkCancellation()
            return image
        }

        // Keep development independent of the Zoom caller's cancellation so
        // navigating away still leaves a reusable disk entry.
        let task = Task<CGImage, Error>(priority: .userInitiated) {
            defer { withExtendedLifetime(access) {} }
            if let cached = await fullSizeCache.load(for: url, variant: .developedRAW) {
                try Task.checkCancellation()
                return cached
            }
            try Task.checkCancellation()
            let data = try await SonyRawFormat.createFullSizeJPEG(from: url, quality: 1.0, useRAW9: true)
            try Task.checkCancellation()
            guard let image = OrientationNormalizedImageLoader.loadCGImage(from: data) else {
                throw SonyJPEGCreationError.encodingFailed
            }
            await fullSizeCache.save(data, for: url, variant: .developedRAW)
            return image
        }
        developedTasks[url] = task
        defer { developedTasks[url] = nil }
        let image = try await task.value
        try Task.checkCancellation()
        return image
    }

    func clearImageCaches() async throws {
        guard !isClearingCaches else { return }
        isClearingCaches = true
        cacheGeneration += 1
        previewMemoryCache.removeAll()
        defer { isClearingCaches = false }
        let tasks = Array(thumbnailTasks.values)
        let previews = Array(extractedJPGTasks.values)
        let developments = Array(developedTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in previews {
            task.cancel()
        }
        for task in developments {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
        for task in previews {
            _ = await task.value
        }
        for task in developments {
            _ = await task.result
        }
        await RAW9PreviewRenderer.zoom.clearPreviewCache()
        await MemoryImageCache.shared.clear()
        try await ThumbnailDiskCache.shared.clear()
        try await fullSizeCache.clear()
    }

    func metadata(for url: URL) async -> RawImageMetadata? {
        let access = await CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        return await RawParserKit.RawImageLoader.shared.metadata(for: url)
    }

    @concurrent static func resizedPreview(_ image: CGImage, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let limit = max(1, maxPixelSize)
        let longest = max(image.width, image.height)
        guard longest > limit else { return image }
        let scale = Double(limit) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !Task.isCancelled else { return nil }
        return context.makeImage()
    }

    private nonisolated static func loadCGImage(from url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            OrientationNormalizedImageLoader.loadCGImage(from: url)
        }.value
    }

    /// Returns camera-authored JPEG bytes only when they match the preview
    /// selected by RawParserKit, avoiding a second lossy full-size encode.
    @concurrent private static func embeddedPreviewJPEGData(
        for url: URL,
        matchingPixelWidth pixelWidth: Int,
        height pixelHeight: Int,
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }

        switch url.pathExtension.lowercased() {
        case SupportedFileType.arw.rawValue:
            guard let locations = SonyMakerNoteParser.embeddedJPEGLocations(from: url) else {
                return nil
            }
            for location in [locations.fullJPEG, locations.preview, locations.thumbnail].compactMap(\.self) {
                guard !Task.isCancelled else { return nil }
                if let data = SonyMakerNoteParser.readEmbeddedJPEGData(at: location, from: url),
                   jpegData(data, matchesPixelWidth: pixelWidth, height: pixelHeight) {
                    return data
                }
            }

        case SupportedFileType.nef.rawValue:
            guard let locations = NikonMakerNoteParser.embeddedJPEGLocations(from: url) else {
                return nil
            }
            for location in [locations.preview, locations.ifd1JPEG].compactMap(\.self) {
                guard !Task.isCancelled else { return nil }
                if let data = NikonMakerNoteParser.readEmbeddedJPEGData(at: location, from: url),
                   jpegData(data, matchesPixelWidth: pixelWidth, height: pixelHeight) {
                    return data
                }
            }

        default:
            return nil
        }
        return nil
    }

    private nonisolated static func jpegData(
        _ data: Data,
        matchesPixelWidth pixelWidth: Int,
        height pixelHeight: Int,
    ) -> Bool {
        guard let dimensions = jpegPixelDimensions(from: data) else { return false }
        return (dimensions.width == pixelWidth && dimensions.height == pixelHeight)
            || (dimensions.width == pixelHeight && dimensions.height == pixelWidth)
    }

    private nonisolated static func jpegPixelDimensions(
        from data: Data,
    ) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  options,
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (width, height)
    }

    /// Called from background discovery; only files directly inside this folder contribute.
    nonisolated static func folderItem(
        at folderURL: URL,
        supportsRAW9: ((URL) -> Bool)? = nil,
    ) -> BrowserFolderItem {
        let rawExtensions = RawFormatRegistry.allExtensions
        let supported = rawExtensions.union(SupportedFileType.renderedImageExtensions)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        )) ?? []
        var count = 0
        var hasRAW9Files = false
        for url in children {
            guard !Task.isCancelled else { break }
            let fileExtension = url.pathExtension.lowercased()
            guard supported.contains(fileExtension),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            count += 1
            if let supportsRAW9, !hasRAW9Files, rawExtensions.contains(fileExtension),
               !SupportedFileType.isRenderedImage(url)
            {
                hasRAW9Files = supportsRAW9(url)
            }
        }
        return BrowserFolderItem(
            url: folderURL,
            supportedFileCount: count,
            hasCLIPIndex: CLIPIndexPaths.containsIndex(in: folderURL),
            hasRAW9Files: hasRAW9Files,
        )
    }
}
