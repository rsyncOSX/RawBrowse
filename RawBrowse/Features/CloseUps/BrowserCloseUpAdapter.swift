import Foundation
import CoreGraphics
import PhotoEvidenceContracts
import PhotoEvidenceEngine

/// Host adapter for RawBrowse's catalog access and existing image services.
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
        guard fingerprint == request.frame.revision else { throw CloseUpRenderError.sourceChanged }
        try Task.checkCancellation()
        guard let source = await BrowserImageLoader.shared.previewImage(for: url) else {
            throw CloseUpRenderError.unavailable
        }
        try Task.checkCancellation()
        let result = try CloseUpRasterizer.render(source, request: request,
            sourceLabel: SupportedFileType.isRenderedImage(url) ? "Original image" : "Embedded preview")
        try Task.checkCancellation()
        guard fingerprint == ImageSourceFingerprint.key(for: url) else {
            throw CloseUpRenderError.sourceChanged
        }
        return result
    }

}
