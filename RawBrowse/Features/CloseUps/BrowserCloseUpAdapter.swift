import Foundation
import CoreGraphics
import PhotoEvidenceContracts
import PhotoEvidenceEngine

/// Host adapter for RawBrowse's catalog access and existing image services.
actor BrowserCloseUpRenderer: CloseUpRendering {
    private var plans: [URL: BrowserCloseUpRenderPlan] = [:]
    private let loadSource: @Sendable (BrowserCloseUpRenderPlan) async throws -> BrowserCloseUpDecodedImage

    init(loadSource: @escaping @Sendable (BrowserCloseUpRenderPlan) async throws -> BrowserCloseUpDecodedImage = {
        try await BrowserCloseUpDecodedSource.load($0)
    }) { self.loadSource = loadSource }

    func configure(_ plans: [BrowserCloseUpRenderPlan]) {
        self.plans = Dictionary(plans.map { ($0.frame.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    // Awaiting the predecessor also bounds requests across actor reentrancy.
    private var tail: Task<CloseUpRender, Error>?
    private var tailID: UUID?

    func render(_ request: CloseUpRequest) async throws -> CloseUpRender {
        guard let plan = plans[request.frame.id], plan.frame.revision == request.frame.revision,
              plan.source == request.renderSource else { throw CloseUpRenderError.sourceChanged }
        let loadSource = loadSource
        let previous = tail
        let id = UUID()
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await Self.makeRender(request, plan: plan, loadSource: loadSource)
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

    @concurrent private static func makeRender(_ request: CloseUpRequest, plan: BrowserCloseUpRenderPlan,
                                        loadSource: @Sendable (BrowserCloseUpRenderPlan) async throws -> BrowserCloseUpDecodedImage) async throws -> CloseUpRender {
        let url = request.frame.id
        let access = await CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        let fingerprint = ImageSourceFingerprint.key(for: url)
        guard fingerprint == request.frame.revision else { throw CloseUpRenderError.sourceChanged }
        try Task.checkCancellation()
        let source = try await loadSource(plan)
        try Task.checkCancellation()
        let result = try CloseUpRasterizer.render(source.image, request: request,
            sourceLabel: source.label, sourceToRenderTransform: source.transform)
        try Task.checkCancellation()
        guard fingerprint == ImageSourceFingerprint.key(for: url) else {
            throw CloseUpRenderError.sourceChanged
        }
        return result
    }

}
