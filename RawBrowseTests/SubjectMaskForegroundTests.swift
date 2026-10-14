import CoreGraphics
import Foundation
@testable import RawBrowse
import Testing

@Suite("Subject mask foreground")
struct SubjectMaskForegroundTests {
    @Test
    func grayscaleUsesIntensityAndRespectsPaddedRows() throws {
        let mask = try grayscale([0, 255, 99, 99, 255, 0, 99, 99], width: 2, height: 2, rowBytes: 4)
        let foreground = try SubjectMaskForeground.decode(mask, width: 2, height: 2)
        #expect(foreground.pixels == [0, 255, 255, 0])
        #expect(foreground.foregroundCount == 2)
        #expect(foreground.totalCoverage == 0.5)
    }

    @Test
    func mismatchedDimensionsAreRejected() throws {
        let mask = try grayscale([255, 0, 0, 255], width: 2, height: 2, rowBytes: 2)
        #expect(throws: SubjectMaskDecodingError.unsafeRegistration) {
            try SubjectMaskForeground.decode(mask, width: 4, height: 4)
        }
    }

    @Test
    func alphaMaskUsesTransparency() throws {
        let bytes: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let mask = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let foreground = try SubjectMaskForeground.decode(mask, width: 2, height: 1)
        #expect(foreground.pixels == [0, 255])
        #expect(foreground.foregroundCount == 1)
    }

    @Test
    func detailScoringStaysInsideGrayscaleForeground() async throws {
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        var imagePixels = pixels
        for y in 0 ..< 32 {
            for x in 0 ..< 32 {
                imagePixels[y * 32 + x] = (x + y).isMultiple(of: 2) ? 255 : 0
                if (8 ..< 24).contains(x), (8 ..< 24).contains(y) { pixels[y * 32 + x] = 255 }
            }
        }
        let mask = try grayscale(pixels, width: 32, height: 32, rowBytes: 32)
        let image = try grayscale(imagePixels, width: 32, height: 32, rowBytes: 32)
        let evidence = try #require(await SubjectMaskFocusScorer().score(
            image: image, subjectMask: mask, normalizedAFPoint: CGPoint(x: 0.1, y: 0.1)))
        #expect(evidence.foregroundCount == 256)
        #expect(evidence.usableForegroundCount == 256)
        #expect(evidence.maskCoverage == 0.25)
        #expect(evidence.autofocusInsideMask == false)
    }

    @Test(arguments: [0, 1])
    func emptyAndTinyForegroundCannotProduceDetailScores(count: Int) async throws {
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        if count == 1 { pixels[16 * 32 + 16] = 255 }
        let mask = try grayscale(pixels, width: 32, height: 32, rowBytes: 32)
        let image = try grayscale([UInt8](repeating: 128, count: 32 * 32), width: 32, height: 32, rowBytes: 32)
        await #expect(throws: count == 0 ? SubjectMaskDecodingError.emptyForeground : .insufficientUsablePixels) {
            try await SubjectMaskFocusScorer().score(image: image, subjectMask: mask, normalizedAFPoint: nil)
        }
    }

    private func grayscale(_ bytes: [UInt8], width: Int, height: Int, rowBytes: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                   bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
