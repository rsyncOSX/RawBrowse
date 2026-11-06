import CoreGraphics
import Foundation

/// Rendering boundary. Images are bounded display artifacts, not domain evidence.
nonisolated struct CloseUpRender: Sendable {
    let crop: CGImage
    let overview: CGImage
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceLabel: String
    let displayedBounds: CGRect
}

nonisolated protocol CloseUpRendering: Sendable {
    func render(_ request: CloseUpRequest) async throws -> CloseUpRender
}

nonisolated enum CloseUpRenderError: Error, LocalizedError {
    case unavailable, sourceChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: "The inspection image is unavailable. Retry or choose another image."
        case .sourceChanged: "The source changed while loading. Retry to inspect the updated image."
        }
    }
}
