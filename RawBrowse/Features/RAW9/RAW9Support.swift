import CoreImage
import Foundation
import ImageIO
import OSLog
import RawParserKit

/// Checks the installed decoder's capabilities without rendering sensor data.
nonisolated enum RAW9Support {
    static func preferredVersion(in versions: [CIRAWDecoderVersion]) -> CIRAWDecoderVersion? {
        if versions.contains(.version9) {
            return .version9
        }
        if versions.contains(.version9DNG) {
            return .version9DNG
        }
        return nil
    }

    /// Map a displayed top-left point into the RAW filter's unrotated coordinates.
    static func neutralLocation(normalizedPoint: CGPoint, extent: CGRect, orientation: CGImagePropertyOrientation) -> CGPoint {
        let image = CIImage.empty().cropped(to: extent)
        let transform = image.orientationTransform(forExifOrientation: Int32(orientation.rawValue))
        let displayedExtent = extent.applying(transform)
        let displayedPoint = CGPoint(
            x: displayedExtent.minX + normalizedPoint.x * max(0, displayedExtent.width - 1),
            y: displayedExtent.minY + (1 - normalizedPoint.y) * max(0, displayedExtent.height - 1),
        )
        let point = displayedPoint.applying(transform.inverted())
        return CGPoint(x: min(extent.maxX - 1, max(extent.minX, point.x)),
                       y: min(extent.maxY - 1, max(extent.minY, point.y)))
    }

    @concurrent
    static func isSupported(for url: URL) async -> Bool {
        guard !Task.isCancelled, !SupportedFileType.isRenderedImage(url) else { return false }
        return autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { return false }
            return preferredVersion(in: filter.supportedDecoderVersions) != nil
        }
    }
}

/// Preview-only adjustments; zero offsets and nil white balance preserve camera defaults.
nonisolated struct RAW9Adjustments: Equatable, Sendable, Codable {
    var exposure: Double = 0
    var noiseReduction: Double = 0
    var sharpness: Double = 0
    var contrast: Double = 0
    var temperature: Double?
    var tint: Double?
    var crop: RAW9Crop?
    var shadowBoost: Double?
    var globalToneMap: Double?
}

/// Normalized coordinates in the oriented image, measured from the top left.
nonisolated struct RAW9Crop: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    var aspectRatio: Double?

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
            && (aspectRatio.map { $0.isFinite && $0 > 0 } ?? true)
    }

    func rect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + x * extent.width,
               y: extent.minY + (1 - y - height) * extent.height,
               width: width * extent.width, height: height * extent.height)
            .integral.intersection(extent)
    }
}

nonisolated struct RAW9ToneDefaults: Sendable {
    var shadowBoost: Double = 1
    var globalToneMap: Double = 1
}

/// Keeps the filter and its intermediate render cache off the main actor.
actor RAW9PreviewRenderer {
    static let zoom = RAW9PreviewRenderer(cacheByteLimit: 512 * 1024 * 1024)

    /// Retain completed pixels, rather than relying on a single filter's intermediate cache.
    private var previews: RAW9RenderedPreviewCache

    init(cacheByteLimit: Int = 0) {
        previews = RAW9RenderedPreviewCache(byteLimit: cacheByteLimit)
    }

    func clearPreviewCache() {
        previews.removeAll()
        filter = nil
        sourceURL = nil
        context.clearCaches()
    }

    private var sourceURL: URL?
    private var sourceRevision: RAW9RenderedPreviewCache.Key?
    private var filter: CIRAWFilter?
    private lazy var context = CIContext(options: [.cacheIntermediates: true])
    private var defaultTemperature: Float = 6500
    private var defaultTint: Float = 0
    private var toneDefaults = RAW9ToneDefaults()
    private var defaults: (noise: Float, sharpness: Float, contrast: Float) = (0, 0, 0)

    /// Uses a separate filter so sampling cannot change the preview's cached defaults.
    func whiteBalance(url: URL, normalizedPoint: CGPoint? = nil) throws -> (temperature: Double, tint: Double) {
        try Task.checkCancellation()
        guard let sample = CIRAWFilter(imageURL: url),
              let version = RAW9Support.preferredVersion(in: sample.supportedDecoderVersions)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        sample.decoderVersion = version
        if let point = normalizedPoint {
            let orientation = sample.orientation
            sample.orientation = .up
            guard let extent = sample.outputImage?.extent else { throw CocoaError(.fileReadUnknown) }
            sample.neutralLocation = RAW9Support.neutralLocation(
                normalizedPoint: point, extent: extent, orientation: orientation,
            )
        }
        let temperature = Double(sample.neutralTemperature)
        let tint = Double(sample.neutralTint)
        guard temperature.isFinite, tint.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        return (min(50000, max(2000, temperature)), min(150, max(-150, tint)))
    }

    func toneSettings(url: URL) throws -> RAW9ToneDefaults {
        guard let sample = CIRAWFilter(imageURL: url),
              let version = RAW9Support.preferredVersion(in: sample.supportedDecoderVersions)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        sample.decoderVersion = version
        return Self.toneSettings(filter: sample)
    }

    private static func toneSettings(filter: CIRAWFilter) -> RAW9ToneDefaults {
        RAW9ToneDefaults(shadowBoost: Double(filter.boostShadowAmount),
                         globalToneMap: Double(filter.boostAmount))
    }

    nonisolated static func previewScale(nativeSize: CGSize, maximumDimension: CGFloat?) -> Float {
        guard let maximumDimension, maximumDimension > 0 else { return 1 }
        return Float(min(1, maximumDimension / max(1, nativeSize.width, nativeSize.height)))
    }

    func render(url: URL, adjustments: RAW9Adjustments, bitDepth: RAWPreviewBitDepth = .eightBit,
                maximumDimension: CGFloat? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let key = try RAW9RenderedPreviewCache.Key(url: url, adjustments: adjustments,
                                                  bitDepth: bitDepth, maximumDimension: maximumDimension)
        if let image = previews.image(for: key) {
            Logger.process.debugMessageOnly("RAW 9 preview cache hit: \(url.lastPathComponent)")
            return image
        }
        Logger.process.debugMessageOnly("RAW 9 preview cache miss; rendering: \(url.lastPathComponent)")
        let started = ContinuousClock.now
        if sourceURL != url || sourceRevision?.fileSize != key.fileSize
            || sourceRevision?.modificationDate != key.modificationDate {
            filter = nil
            sourceURL = nil
            guard let loaded = CIRAWFilter(imageURL: url),
                  let version = RAW9Support.preferredVersion(in: loaded.supportedDecoderVersions)
            else { throw CocoaError(.fileReadUnsupportedScheme) }
            loaded.decoderVersion = version
            defaults = (loaded.luminanceNoiseReductionAmount, loaded.sharpnessAmount, loaded.contrastAmount)
            defaultTemperature = loaded.neutralTemperature
            defaultTint = loaded.neutralTint
            toneDefaults = Self.toneSettings(filter: loaded)
            filter = loaded
            sourceURL = url
            sourceRevision = key
        }
        guard let filter else { throw CocoaError(.fileReadUnknown) }
        filter.neutralTemperature = adjustments.temperature.map(Float.init) ?? defaultTemperature
        filter.neutralTint = adjustments.tint.map(Float.init) ?? defaultTint
        filter.exposure = Float(adjustments.exposure)
        filter.boostAmount = Float(adjustments.globalToneMap ?? toneDefaults.globalToneMap)
        filter.boostShadowAmount = Float(adjustments.shadowBoost ?? toneDefaults.shadowBoost)
        // Full resolution remains the default for zoom and export; crop uses a smaller preview.
        filter.scaleFactor = Self.previewScale(nativeSize: filter.nativeSize, maximumDimension: maximumDimension)
        filter.luminanceNoiseReductionAmount = min(1, max(0, defaults.noise + Float(adjustments.noiseReduction)))
        filter.sharpnessAmount = min(1, max(0, defaults.sharpness + Float(adjustments.sharpness)))
        filter.contrastAmount = min(1, max(0, defaults.contrast + Float(adjustments.contrast)))
        // Finish the expensive RAW render on this actor. A deferred CGImage can
        // perform that work when SwiftUI draws it, blocking the main thread.
        guard var output = filter.outputImage else { throw CocoaError(.fileReadUnknown) }
        if let crop = adjustments.crop {
            guard crop.isValid else { throw CocoaError(.fileReadCorruptFile) }
            output = output.cropped(to: crop.rect(in: output.extent))
        }
        guard let image = context.createCGImage(
            output, from: output.extent, format: bitDepth == .eightBit ? .RGBA8 : .RGBAh,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            deferred: false,
        )
        else { throw CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        previews.insert(image, for: key)
        Logger.process.debugMessageOnly("RAW 9 render completed: \(url.lastPathComponent), \(started.duration(to: .now)), cached bytes: \(previews.byteCount)")
        return image
    }

    /// ImageIO supplies the writable formats installed on this Mac.
    nonisolated static var exportTypes: [String] {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).sorted()
    }

    func export(url: URL, adjustments: RAW9Adjustments, destination: URL, type: String, heif10: Bool = false) throws {
        let image = try render(url: url, adjustments: adjustments, bitDepth: .sixteenBit)
        try writeExport(image: image, destination: destination, type: type, heif10: heif10)
    }

    func writeExport(image: CGImage, destination: URL, type: String, heif10: Bool = false) throws {
        let ciImage = CIImage(cgImage: image)
        let highDepth = type == "public.png" || type == "public.tiff"
        guard let encodedImage = context.createCGImage(ciImage, from: ciImage.extent,
                                                       format: highDepth ? .RGBA16 : .RGBA8,
                                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw CocoaError(.fileWriteUnknown) }
        // A save-panel grant covers the destination, not arbitrary siblings.
        // Foundation chooses a writable staging directory on the same volume.
        let stagingDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true,
        )
        let temporary = stagingDirectory.appendingPathComponent(destination.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        if type == "com.ilm.openexr-image" {
            try context.writeOpenEXRRepresentation(of: ciImage, to: temporary, options: [:])
        } else if heif10 {
            try context.writeHEIF10Representation(of: ciImage, to: temporary,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  options: [:])
        } else {
            guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, type as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(writer, encodedImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

/// An app-specific sidecar, separate from XMP used by other photo editors.
actor RAW9SidecarStore {
    private struct Document: Codable {
        var version: Int = 1
        var adjustments: RAW9Adjustments
    }

    nonisolated static func sidecarURL(for rawURL: URL) -> URL {
        rawURL.appendingPathExtension("rawcull-raw9.json")
    }

    func load(for rawURL: URL) throws -> RAW9Adjustments? {
        let url = Self.sidecarURL(for: rawURL)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, Self.isValid(document.adjustments) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document.adjustments
    }

    func save(_ adjustments: RAW9Adjustments, for rawURL: URL) throws {
        guard Self.isValid(adjustments) else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(adjustments: adjustments))
        try data.write(to: Self.sidecarURL(for: rawURL), options: .atomic)
    }

    private nonisolated static func isValid(_ value: RAW9Adjustments) -> Bool {
        (value.crop.map(\.isValid) ?? true)
            && (value.temperature.map { $0.isFinite && (2000 ... 50000).contains($0) } ?? true)
            && (value.tint.map { $0.isFinite && (-150 ... 150).contains($0) } ?? true)
            && (value.shadowBoost.map { $0.isFinite && (0 ... 2).contains($0) } ?? true)
            && (value.globalToneMap.map { $0.isFinite && (0 ... 1).contains($0) } ?? true)
            && value.exposure.isFinite && (-3 ... 3).contains(value.exposure)
            && value.noiseReduction.isFinite && (-1 ... 1).contains(value.noiseReduction)
            && value.sharpness.isFinite && (-1 ... 1).contains(value.sharpness)
            && value.contrast.isFinite && (-1 ... 1).contains(value.contrast)
    }
}

/// Lossless, byte-bounded LRU cache. Owned exclusively by the preview renderer actor.
nonisolated struct RAW9RenderedPreviewCache {
    struct Key: Equatable {
        let url: URL
        let fileSize: Int
        let modificationDate: Date
        let adjustments: RAW9Adjustments
        let bitDepth: RAWPreviewBitDepth
        let maximumDimension: CGFloat?

        init(url: URL, adjustments: RAW9Adjustments, bitDepth: RAWPreviewBitDepth,
             maximumDimension: CGFloat? = nil) throws {
            self.url = url.standardizedFileURL
            let values = try self.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let fileSize = values.fileSize, let modificationDate = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            self.fileSize = fileSize
            self.modificationDate = modificationDate
            self.adjustments = adjustments
            self.bitDepth = bitDepth
            self.maximumDimension = maximumDimension
        }
    }

    private struct Entry {
        let key: Key
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
    }

    let byteLimit: Int
    private var entries: [Entry] = []
    private(set) var byteCount = 0

    mutating func image(for key: Key) -> CGImage? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: Key) {
        let entry = Entry(key: key, image: image)
        guard entry.cost <= byteLimit else { return }
        // Retain one adjustment version per source to avoid filling the cache while dragging a slider.
        for index in entries.indices.reversed() where entries[index].key.url == key.url {
            byteCount -= entries.remove(at: index).cost
        }
        while byteCount + entry.cost > byteLimit, !entries.isEmpty {
            byteCount -= entries.removeFirst().cost
        }
        entries.append(entry)
        byteCount += entry.cost
    }

    mutating func removeAll() {
        entries.removeAll()
        byteCount = 0
    }
}
