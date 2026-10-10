import CoreImage
import Foundation
import ImageIO
@testable import RawBrowse
import Testing

@Suite("RAW 9 sidecars")
struct RAW9SidecarStoreTests {
    private func temporaryRAW() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("photo.ARW")
    }

    @Test func `saves restores and resets without changing original`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let original = Data("original raw bytes".utf8)
        try original.write(to: raw)
        let store = RAW9SidecarStore()
        #expect(try await store.load(for: raw) == nil)
        let adjustments = RAW9Adjustments(exposure: 1.2, noiseReduction: -0.3, sharpness: 0.4, contrast: 0.2, temperature: 5200, tint: -12)
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        #expect(RAW9SidecarStore.sidecarURL(for: raw).lastPathComponent == "photo.ARW.rawcull-raw9.json")
        try await store.save(RAW9Adjustments(), for: raw)
        #expect(try await store.load(for: raw) == RAW9Adjustments())
        #expect(try Data(contentsOf: raw) == original)
    }

    @Test func `crop round trips with ratio and uses top left coordinates`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let crop = RAW9Crop(x: 0.1, y: 0.2, width: 0.5, height: 0.5, aspectRatio: 4.0 / 3)
        let adjustments = RAW9Adjustments(crop: crop)
        let store = RAW9SidecarStore()
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        #expect(crop.rect(in: CGRect(x: 10, y: 20, width: 400, height: 300)) == CGRect(x: 50, y: 110, width: 200, height: 150))
    }

    @Test(arguments: [
        RAW9Crop(x: -0.1), RAW9Crop(width: 0), RAW9Crop(x: 0.5, width: 0.6),
        RAW9Crop(height: .infinity), RAW9Crop(aspectRatio: -1)
    ])
    func `rejects invalid crops`(crop: RAW9Crop) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let store = RAW9SidecarStore()
        await #expect(throws: (any Error).self) { try await store.save(RAW9Adjustments(crop: crop), for: raw) }
    }

    @Test(arguments: ["public.jpeg", "public.png", "public.tiff", "public.heic", "com.ilm.openexr-image", "heif10"])
    func `exports readable full size images`(type: String) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let destination = raw.deletingLastPathComponent().appendingPathComponent("export")
        let input = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(CIContext().createCGImage(input, from: input.extent))
        let renderer = RAW9PreviewRenderer()
        try await renderer.writeExport(image: image, destination: destination,
                                       type: type == "heif10" ? "public.heic" : type, heif10: type == "heif10")
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let exported = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(exported.width == 32)
        #expect(exported.height == 24)
        if type == "public.png" || type == "public.tiff" {
            #expect(exported.bitsPerComponent == 16)
        }
        // Replacing an existing export also completes without leaving temporary files.
        try await renderer.writeExport(image: image, destination: destination,
                                       type: type == "heif10" ? "public.heic" : type, heif10: type == "heif10")
        #expect(try FileManager.default.contentsOfDirectory(atPath: raw.deletingLastPathComponent().path) == ["export"])
    }

    @Test func `zero saturation renders gray and neutral controls preserve pixels`() throws {
        let input = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let context = CIContext()
        func pixel(_ adjustments: RAW9Adjustments) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let output = RAW9PreviewRenderer.applyColorAdjustments(to: input, adjustments: adjustments)
            bytes.withUnsafeMutableBytes { buffer in
                context.render(output, toBitmap: buffer.baseAddress!, rowBytes: 4, bounds: input.extent,
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes
        }
        #expect(pixel(RAW9Adjustments()) == pixel(RAW9Adjustments(overallContrast: 1, saturation: 1, vibrance: 0)))
        let gray = pixel(RAW9Adjustments(saturation: 0))
        #expect(abs(Int(gray[0]) - Int(gray[1])) <= 1)
        #expect(abs(Int(gray[1]) - Int(gray[2])) <= 1)
        #expect(pixel(RAW9Adjustments(vibrance: 1)) != pixel(RAW9Adjustments()))
        #expect(pixel(RAW9Adjustments(overallContrast: 1.8)) != pixel(RAW9Adjustments()))
    }

    @Test func `new color controls round trip and legacy values stay neutral`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let store = RAW9SidecarStore()
        let adjustments = RAW9Adjustments(exposure: 5, overallContrast: 1.6, saturation: 1.8, vibrance: -0.4)
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        let legacy = try JSONDecoder().decode(RAW9Adjustments.self, from: Data(
            #"{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0}"#.utf8))
        #expect(legacy == RAW9Adjustments())
    }

    @Test(arguments: ["public.jpeg", "public.tiff", "public.heic", "heif10"])
    func `exports preserve capture metadata and update geometry`(type: String) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let input = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(CIContext().createCGImage(input, from: input.extent))
        let writer = try #require(CGImageDestinationCreateWithURL(raw as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.008,
                                            kCGImagePropertyExifDateTimeOriginal: "2026:10:10 12:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 59.9,
                                           kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        let destination = raw.deletingLastPathComponent().appendingPathComponent("export")
        try await RAW9PreviewRenderer().writeExport(image: image, destination: destination,
            type: type == "heif10" ? "public.heic" : type, heif10: type == "heif10", sourceURL: raw)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:10 12:00:00")
        #expect(exif[kCGImagePropertyExifExposureTime as String] as? Double == 0.008)
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 32)
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "Test Camera")
        if type == "heif10" {
            #expect(properties[kCGImagePropertyDepth as String] as? Int == 10)
        }
        let gps = try #require(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(gps[kCGImagePropertyGPSLatitude as String] as? Double == 59.9)
    }

    @Test func `picker maps displayed coordinates into unrotated RAW pixels`() {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let landscape = RAW9Support.neutralLocation(normalizedPoint: CGPoint(x: 0.25, y: 0.75), extent: extent, orientation: .up)
        #expect(abs(landscape.x - 99.75) < 0.01)
        #expect(abs(landscape.y - 74.75) < 0.01)
        let portrait = RAW9Support.neutralLocation(normalizedPoint: CGPoint(x: 0.25, y: 0.75), extent: extent, orientation: .right)
        #expect(abs(portrait.x - 300.25) < 0.01)
        #expect(abs(portrait.y - 74.75) < 0.01)
    }

    @Test func `loads legacy sidecars with camera white balance`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let contents = #"{"version":1,"adjustments":{"exposure":1,"noiseReduction":0,"sharpness":0,"contrast":0}}"#
        try Data(contents.utf8).write(to: RAW9SidecarStore.sidecarURL(for: raw))
        let store = RAW9SidecarStore()
        let adjustments = try #require(try await store.load(for: raw))
        #expect(adjustments.exposure == 1)
        #expect(adjustments.temperature == nil)
        #expect(adjustments.tint == nil)
        #expect(adjustments.crop == nil)
        #expect(adjustments.shadowBoost == nil)
        #expect(adjustments.globalToneMap == nil)
    }

    @Test func `tone adjustments round trip and reset to camera defaults`() async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let store = RAW9SidecarStore()
        let adjustments = RAW9Adjustments(shadowBoost: 1.4, globalToneMap: 0.8)
        try await store.save(adjustments, for: raw)
        #expect(try await store.load(for: raw) == adjustments)
        try await store.save(RAW9Adjustments(), for: raw)
        #expect(try await store.load(for: raw) == RAW9Adjustments())
    }

    @Test(arguments: [
        RAW9Adjustments(overallContrast: 2.1), RAW9Adjustments(saturation: -0.1),
        RAW9Adjustments(vibrance: .infinity), RAW9Adjustments(vibrance: 1.1),
        RAW9Adjustments(exposure: 5.1),
        RAW9Adjustments(shadowBoost: -0.1), RAW9Adjustments(shadowBoost: 2.1),
        RAW9Adjustments(globalToneMap: 1.1),
        RAW9Adjustments(shadowBoost: .infinity)
    ])
    func `rejects invalid tone adjustments`(adjustments: RAW9Adjustments) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        let store = RAW9SidecarStore()
        await #expect(throws: (any Error).self) { try await store.save(adjustments, for: raw) }
    }

    @Test func `preview scaling caps dimensions without enlarging small images`() {
        #expect(RAW9PreviewRenderer.previewScale(nativeSize: CGSize(width: 6000, height: 4000), maximumDimension: 1200) == 0.2)
        #expect(RAW9PreviewRenderer.previewScale(nativeSize: CGSize(width: 4000, height: 6000), maximumDimension: 1200) == 0.2)
        #expect(RAW9PreviewRenderer.previewScale(nativeSize: CGSize(width: 640, height: 480), maximumDimension: 1280) == 1)
        #expect(RAW9PreviewRenderer.previewScale(nativeSize: CGSize(width: 6000, height: 4000), maximumDimension: nil) == 1)
    }

    @Test(arguments: [
        #"{"version":1,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0,"temperature":1000}}"#,
        #"{"version":1,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0,"tint":151}}"#,
        "not JSON",
        #"{"version":2,"adjustments":{"exposure":0,"noiseReduction":0,"sharpness":0,"contrast":0}}"#,
        #"{"version":1,"adjustments":{"exposure":10,"noiseReduction":0,"sharpness":0,"contrast":0}}"#
    ])
    func `rejects invalid sidecars`(contents: String) async throws {
        let raw = try temporaryRAW()
        defer { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        try Data(contents.utf8).write(to: RAW9SidecarStore.sidecarURL(for: raw))
        let store = RAW9SidecarStore()
        await #expect(throws: (any Error).self) { try await store.load(for: raw) }
    }
}
