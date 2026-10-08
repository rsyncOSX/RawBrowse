import AppKit
import ImageIO
import RawParserKit

actor BrowserImageLoader {
    static let shared = BrowserImageLoader()

    private struct ImageTaskKey: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    private var thumbnailTaskIDs: [ImageTaskKey: UUID] = [:]
    private var thumbnailTasks: [ImageTaskKey: Task<NSImage?, Never>] = [:]
    private var extractedJPGTasks: [URL: Task<CGImage?, Never>] = [:]
    private var extractedJPGTaskIDs: [URL: UUID] = [:]

    private var developedTasks: [URL: Task<CGImage, Error>] = [:]

    private var isClearingCaches = false
    private var cacheGeneration = 0

    private let extractPreview: @Sendable (URL) async -> CGImage?

    init(fullSizeCache: FullSizeJPGDiskCache = .shared, extractPreview: @escaping @Sendable (URL) async -> CGImage? = {
        await RawParserKit.RawImageLoader.shared.previewImage(for: $0)
    }) {
        self.fullSizeCache = fullSizeCache
        self.extractPreview = extractPreview
    }

    private let fullSizeCache: FullSizeJPGDiskCache

    func discoverFolders(at folderURL: URL) async -> [BrowserFolderItem] {
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
                return Self.folderItem(at: url)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    func folderItem(at folderURL: URL) async -> BrowserFolderItem {
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        return await Task.detached(priority: .utility) {
            Self.folderItem(at: folderURL)
        }.value
    }

    func discoverSupportedFiles(at folderURL: URL) async -> [BrowserFileItem] {
        let access = await CatalogAccess.shared.lease(for: folderURL)
        defer { withExtendedLifetime(access) {} }
        return await Task.detached(priority: .utility) {
            let supported = RawFormatRegistry.allExtensions.union(SupportedFileType.renderedImageExtensions)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
            ) else { return [] }

            let files = children.compactMap { url -> BrowserFileItem? in
                guard supported.contains(url.pathExtension.lowercased()) else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true, values?.isHidden != true else { return nil }
                return BrowserFileItem(url: url)
            }
            let renderedImageFiles = files.filter { SupportedFileType.isRenderedImage($0.url) }
            return (renderedImageFiles.isEmpty ? files : renderedImageFiles)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    func thumbnail(for url: URL, targetSize: Int = 200) async -> NSImage? {
        let access = await CatalogAccess.shared.lease(for: url)
        guard !isClearingCaches else { return nil }
        let boundedTargetSize = max(targetSize, 1)
        let taskKey = ImageTaskKey(url: url, maxPixelSize: boundedTargetSize)

        if let cached = await MemoryImageCache.shared.thumbnail(for: url, maxPixelSize: boundedTargetSize) {
            return cached
        }

        guard !isClearingCaches else { return nil }
        if let existing = thumbnailTasks[taskKey] {
            return await existing.value
        }

        let taskID = UUID()
        let generation = cacheGeneration
        let task = Task<NSImage?, Never>(priority: .utility) {
            defer { withExtendedLifetime(access) {} }
            guard !Task.isCancelled else { return nil }
            if let diskImage = await ThumbnailDiskCache.shared.load(
                for: url,
                maxPixelSize: boundedTargetSize,
            ) {
                guard !Task.isCancelled, generation == cacheGeneration else { return nil }
                await MemoryImageCache.shared.storeThumbnail(
                    diskImage,
                    for: url,
                    maxPixelSize: boundedTargetSize,
                )
                return diskImage
            }

            guard let image = await RawParserKit.RawImageLoader.shared.thumbnail(
                for: url,
                maxPixelSize: boundedTargetSize,
            ), !Task.isCancelled else { return nil }

            guard generation == cacheGeneration else { return nil }
            await MemoryImageCache.shared.storeThumbnail(image, for: url, maxPixelSize: boundedTargetSize)
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
        let image = await task.value
        if thumbnailTaskIDs[taskKey] == taskID {
            thumbnailTasks[taskKey] = nil
            thumbnailTaskIDs[taskKey] = nil
        }
        return image
    }

    func previewImage(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, let image = await fullSizePreview(for: url), !Task.isCancelled else { return nil }
        return await Self.resizedPreview(image, maxPixelSize: maxPixelSize)
    }

    private func fullSizePreview(for url: URL) async -> CGImage? {
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
                return await Self.loadCGImage(from: url)
            }

            if let cached = await fullSizeCache.load(for: url) {
                guard !Task.isCancelled else { return nil }
                return cached
            }

            let extracted = await extractPreview(url)
            guard !Task.isCancelled else { return nil }

            if let extracted {
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
        let image = await task.value
        if extractedJPGTaskIDs[url] == taskID {
            extractedJPGTasks[url] = nil
            extractedJPGTaskIDs[url] = nil
        }
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

    private nonisolated static func supportedFileCount(in folderURL: URL) -> Int {
        let supported = RawFormatRegistry.allExtensions.union(SupportedFileType.renderedImageExtensions)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else { return 0 }

        let supportedFiles = children.filter { url in
            guard supported.contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        let renderedImageCount = supportedFiles.count(where: SupportedFileType.isRenderedImage)
        return renderedImageCount > 0 ? renderedImageCount : supportedFiles.count
    }

    private nonisolated static func folderItem(at folderURL: URL) -> BrowserFolderItem {
        BrowserFolderItem(
            url: folderURL,
            supportedFileCount: supportedFileCount(in: folderURL),
            hasCLIPIndex: CLIPIndexPaths.containsIndex(in: folderURL),
        )
    }
}
