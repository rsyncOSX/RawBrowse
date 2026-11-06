import CoreGraphics
import Foundation
import PhotoEvidenceContracts
import PhotoEvidenceEngine

nonisolated struct BrowserCloseUpDecodedImage: Sendable {
    let image: CGImage
    let label: String
    var transform: CloseUpCoordinateTransform = .identity
}

/// Decoding stays in the host. Never changes the active RAW editing session.
enum BrowserCloseUpDecodedSource {
    @concurrent static func load(_ plan: BrowserCloseUpRenderPlan) async throws -> BrowserCloseUpDecodedImage {
        switch plan.backend {
        case .original, .embedded:
            guard let image = await BrowserImageLoader.shared.previewImage(for: plan.frame.id) else {
                throw CloseUpRenderError.unavailable
            }
            return BrowserCloseUpDecodedImage(image: image,
                label: plan.backend == .original ? "Original image" : "Embedded preview")
        case .raw:
            let image = try await BrowserImageLoader.shared.developedPreview(for: plan.frame.id)
            return BrowserCloseUpDecodedImage(image: image, label: "RAW decoded")
        case .raw9:
            let adjustments: RAW9Adjustments
            if let live = plan.adjustments { adjustments = live }
            else {
                let sidecar = RAW9SidecarStore.sidecarURL(for: plan.frame.id)
                guard ImageSourceFingerprint.key(for: sidecar) == plan.sidecarRevision else {
                    throw CloseUpRenderError.sourceChanged
                }
                adjustments = try await RAW9SidecarStore().load(for: plan.frame.id) ?? RAW9Adjustments()
                guard ImageSourceFingerprint.key(for: sidecar) == plan.sidecarRevision else {
                    throw CloseUpRenderError.sourceChanged
                }
            }
            try Task.checkCancellation()
            // Native dimensions are required for a truthful source-pixel inspection.
            let image = try await RAW9PreviewRenderer.zoom.render(url: plan.frame.id,
                adjustments: adjustments, bitDepth: plan.bitDepth, maximumDimension: nil)
            try Task.checkCancellation()
            return BrowserCloseUpDecodedImage(image: image,
                label: "RAW 9 decoded · \(plan.bitDepth == .eightBit ? "8-bit" : "16-bit")",
                transform: coordinateTransform(adjustments: adjustments, renderedSize: CGSize(width: image.width, height: image.height)))
        }
    }

    /// Matches the host's straighten-then-crop pipeline. Saved choices stay in
    /// canonical oriented coordinates even when the developed output is cropped.
    nonisolated static func coordinateTransform(adjustments: RAW9Adjustments,
                                               renderedSize: CGSize) -> CloseUpCoordinateTransform {
        let crop = adjustments.crop ?? RAW9Crop()
        let size = CGSize(width: renderedSize.width / crop.width, height: renderedSize.height / crop.height)
        func mapped(_ point: CGPoint) -> CGPoint {
            let straight = RAW9Straightening.displayedPoint(point, imageSize: size,
                degrees: adjustments.straightenAngle ?? 0)
            return CGPoint(x: (straight.x - crop.x) / crop.width, y: (straight.y - crop.y) / crop.height)
        }
        let origin = mapped(.zero)
        let x = mapped(CGPoint(x: 1, y: 0))
        let y = mapped(CGPoint(x: 0, y: 1))
        return CloseUpCoordinateTransform(a: x.x - origin.x, b: x.y - origin.y,
            c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
    }
}
