import CoreGraphics
import CryptoKit
import Foundation
import PhotoEvidenceContracts

nonisolated struct BrowserCloseUpFile: Equatable, Sendable {
    let url: URL
    let refreshRevision: UUID
}

nonisolated struct BrowserCloseUpRenderingInputs: Equatable, Sendable {
    let files: [BrowserCloseUpFile]
    let reference: CloseUpFrame?
    let developRAW: Bool
    let bitDepth: RAWPreviewBitDepth
    let liveAdjustments: [URL: RAW9Adjustments]
}

/// Immutable settings captured before publishing the matching package descriptor.
nonisolated struct BrowserCloseUpRenderPlan: Equatable, Sendable {
    enum Backend: String, Sendable { case original, embedded, raw, raw9 }
    let frame: CloseUpFrame
    let backend: Backend
    let bitDepth: RAWPreviewBitDepth
    let adjustments: RAW9Adjustments?
    let sidecarRevision: String?
    let source: CloseUpRenderSource

    init(frame: CloseUpFrame, backend: Backend, bitDepth: RAWPreviewBitDepth,
         adjustments: RAW9Adjustments? = nil, sidecarRevision: String? = nil) throws {
        self.frame = frame
        self.backend = backend
        self.bitDepth = bitDepth
        self.adjustments = adjustments
        self.sidecarRevision = sidecarRevision
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let settings = try adjustments.map { try encoder.encode($0) } ?? Data()
        var token = Data("native-v1|\(backend.rawValue)|\(bitDepth.rawValue)|\(sidecarRevision ?? "live")|".utf8)
        token.append(settings)
        let revision = SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
        let kind: CloseUpRenderSource.Kind = switch backend {
        case .original: .original
        case .embedded: .embeddedPreview
        case .raw, .raw9: .developedRAW
        }
        source = CloseUpRenderSource(kind: kind, backendID: backend.rawValue, revision: revision)
    }
}

actor BrowserCloseUpSourcePlanner {
    private var supportCache: [String: Bool] = [:]
    private let supportsRAW9: @Sendable (URL) async -> Bool

    init(supportsRAW9: @escaping @Sendable (URL) async -> Bool = { await RAW9Support.isSupported(for: $0) }) {
        self.supportsRAW9 = supportsRAW9
    }

    func prepare(_ inputs: BrowserCloseUpRenderingInputs) async throws -> [BrowserCloseUpRenderPlan] {
        var files = inputs.files.map { BrowserFileItem(url: $0.url) }
        if let reference = inputs.reference, !files.contains(where: { $0.url == reference.id }) {
            files.append(BrowserFileItem(url: reference.id))
        }
        let frames = await BrowserCloseUpFrameAdapter.frames(for: files)
        var plans: [BrowserCloseUpRenderPlan] = []
        for frame in frames {
            try Task.checkCancellation()
            let access = await CatalogAccess.shared.lease(for: frame.id)
            defer { withExtendedLifetime(access) {} }
            let backend: BrowserCloseUpRenderPlan.Backend
            if SupportedFileType.isRenderedImage(frame.id) { backend = .original }
            else if !inputs.developRAW { backend = .embedded }
            else {
                let supported: Bool
                if let cached = supportCache[frame.revision] { supported = cached }
                else {
                    supported = await supportsRAW9(frame.id)
                    if supportCache.count > 64 { supportCache.removeAll() }
                    supportCache[frame.revision] = supported
                }
                backend = supported ? .raw9 : .raw
            }
            let live = backend == .raw9 ? inputs.liveAdjustments[frame.id] : nil
            let sidecar = backend == .raw9 && live == nil
                ? ImageSourceFingerprint.key(for: RAW9SidecarStore.sidecarURL(for: frame.id)) : nil
            plans.append(try BrowserCloseUpRenderPlan(frame: frame, backend: backend,
                bitDepth: inputs.bitDepth, adjustments: live, sidecarRevision: sidecar))
        }
        try Task.checkCancellation()
        return plans
    }
}
