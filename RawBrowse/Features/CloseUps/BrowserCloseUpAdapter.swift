import Foundation
import CoreGraphics

/// The only Close-ups boundary that knows about RawBrowse's catalog/image services.
actor BrowserCloseUpRenderer: CloseUpRendering {
    // Awaiting the predecessor also bounds requests across actor reentrancy.
    private var tail: Task<CloseUpRender, Error>?
    private var tailID: UUID?

    func render(_ request: CloseUpRequest) async throws -> CloseUpRender {
        let previous = tail
        let id = UUID()
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await Self.makeRender(request)
        }
        tail = task
        tailID = id
        defer {
            if tailID == id {
                tail = nil
                tailID = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @concurrent private static func makeRender(_ request: CloseUpRequest) async throws -> CloseUpRender {
        let url = request.frame.id
        let access = await CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        let fingerprint = ImageSourceFingerprint.key(for: url)
        try Task.checkCancellation()
        guard let source = await BrowserImageLoader.shared.previewImage(for: url) else {
            throw CloseUpRenderError.unavailable
        }
        try Task.checkCancellation()
        let requested = request.region.pixelBounds(width: source.width, height: source.height)
        let scale = max(1, min(4, request.displayScale))
        // Source pixels: one image pixel per display point, bounded to the crop viewport.
        let cropBounds: CGRect
        if request.mode == .sourcePixels {
            let width = min(requested.width, 280)
            let height = min(requested.height, 210)
            cropBounds = CGRect(x: floor(requested.midX - width / 2), y: floor(requested.midY - height / 2),
                                width: width, height: height)
        } else {
            cropBounds = requested
        }
        guard let crop = source.cropping(to: cropBounds),
              let bounded = Self.boundedArtifact(crop, maxPixelSize: Int(280 * scale)),
              let overview = await BrowserImageLoader.resizedPreview(source, maxPixelSize: Int(280 * scale))
        else { throw CloseUpRenderError.unavailable }
        try Task.checkCancellation()
        guard fingerprint == ImageSourceFingerprint.key(for: url) else {
            throw CloseUpRenderError.sourceChanged
        }
        return CloseUpRender(crop: bounded, overview: overview,
            sourceWidth: source.width, sourceHeight: source.height,
            sourceLabel: SupportedFileType.isRenderedImage(url) ? "Original image" : "Embedded preview",
            displayedBounds: CGRect(x: cropBounds.minX / Double(source.width),
                                    y: cropBounds.minY / Double(source.height),
                                    width: cropBounds.width / Double(source.width),
                                    height: cropBounds.height / Double(source.height)))
    }

    /// CGImage.cropping can retain the entire source backing store. Always rasterize
    /// into an independently owned bounded buffer, even for source-pixel crops.
    private nonisolated static func boundedArtifact(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let factor = min(1, Double(maxPixelSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

}

extension BrowserFileItem {
    var closeUpFrame: CloseUpFrame {
        CloseUpFrame(id: url, name: name, revision: id)
    }
}
