import CoreGraphics
import Foundation
@testable import RawBrowse
import Testing

@Suite("RAW preview settings")
struct RAWPreviewSettingsTests {
    @Test func `existing settings default to eight bit`() throws {
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        #expect(settings.rawPreviewBitDepth == .eightBit)
    }

    @Test(arguments: RAWPreviewBitDepth.allCases)
    func `bit depth survives settings round trip`(bitDepth: RAWPreviewBitDepth) throws {
        var settings = BrowserSettings()
        settings.rawPreviewBitDepth = bitDepth
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(BrowserSettings.self, from: encoded)
        #expect(restored.rawPreviewBitDepth == bitDepth)
    }
}

@Suite("RAW 9 completed preview cache")
struct RAW9RenderedPreviewCacheTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func `revisit retains identical pixels and evicts least recently viewed image`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try (0..<3).map { index in
            let url = directory.appendingPathComponent("image\(index).raw")
            try Data([0]).write(to: url)
            return try RAW9RenderedPreviewCache.Key(url: url, adjustments: RAW9Adjustments(), bitDepth: .eightBit)
        }
        let pixels = try image()
        let cost = pixels.bytesPerRow * pixels.height
        var cache = RAW9RenderedPreviewCache(byteLimit: cost * 2)
        cache.insert(pixels, for: keys[0])
        cache.insert(pixels, for: keys[1])
        #expect(cache.image(for: keys[0]) === pixels)
        cache.insert(pixels, for: keys[2])
        #expect(cache.image(for: keys[1]) == nil)
        #expect(cache.image(for: keys[0]) === pixels)
        #expect(cache.byteCount == cost * 2)
        cache.removeAll()
        #expect(cache.image(for: keys[0]) == nil)
        #expect(cache.byteCount == 0)
    }

    @Test func `changed source adjustments depth and dimensions miss the cache`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try RAW9RenderedPreviewCache.Key(url: url, adjustments: RAW9Adjustments(), bitDepth: .eightBit)
        let pixels = try image()
        var cache = RAW9RenderedPreviewCache(byteLimit: pixels.bytesPerRow * pixels.height)
        cache.insert(pixels, for: original)
        var adjustments = RAW9Adjustments()
        adjustments.exposure = 1
        let edited = try RAW9RenderedPreviewCache.Key(url: url, adjustments: adjustments, bitDepth: .eightBit)
        #expect(cache.image(for: edited) == nil)
        #expect(cache.image(for: try .init(url: url, adjustments: RAW9Adjustments(), bitDepth: .sixteenBit)) == nil)
        #expect(cache.image(for: try .init(url: url, adjustments: RAW9Adjustments(), bitDepth: .eightBit, maximumDimension: 1280)) == nil)
        cache.insert(pixels, for: edited)
        #expect(cache.image(for: original) == nil)
        #expect(cache.byteCount == pixels.bytesPerRow * pixels.height)
        try Data([0, 1]).write(to: url)
        #expect(cache.image(for: try .init(url: url, adjustments: adjustments, bitDepth: .eightBit)) == nil)
    }

    @Test func `oversize images are not retained`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = try RAW9RenderedPreviewCache.Key(url: url, adjustments: RAW9Adjustments(), bitDepth: .eightBit)
        var cache = RAW9RenderedPreviewCache(byteLimit: 1)
        cache.insert(try image(), for: key)
        #expect(cache.image(for: key) == nil)
        #expect(cache.byteCount == 0)
    }
}
