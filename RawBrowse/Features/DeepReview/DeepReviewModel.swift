import CoreGraphics
import Foundation
import Observation

@Observable @MainActor
final class DeepReviewModel {
    let deepAIReviewController = DeepAIReviewController()
    @ObservationIgnored private let deepAIReviewRuntime = DeepAIReviewRuntime()
    private(set) var sam3ModelStatus: RawBrowseAICapabilityStatus = .missing(expectedLocations: [])
    @ObservationIgnored private var activeSAM3ModelURL: URL?
    @ObservationIgnored private var sam3ValidationTask: Task<Void, Never>?

    func activateModel(at selectedURL: URL?) {

        let standardizedURL = selectedURL?.standardizedFileURL
        guard activeSAM3ModelURL != standardizedURL else { return }
        validateSAM3Model(at: standardizedURL)
    }

    private func validateSAM3Model(at url: URL?) {
        let standardizedURL = url?.standardizedFileURL
        activeSAM3ModelURL = standardizedURL
        sam3ValidationTask?.cancel()
        sam3ModelStatus = .checking(expectedLocations: standardizedURL.map { [$0] } ?? [])

        sam3ValidationTask = Task { [self] in
            let status = await deepAIReviewRuntime.activateSAM3(
                at: standardizedURL,
                controller: deepAIReviewController,
            )
            guard !Task.isCancelled, activeSAM3ModelURL == standardizedURL else { return }
            sam3ModelStatus = status
            sam3ValidationTask = nil
        }
    }

    func startDeepReview(
        groupID: Int,
        groupSignature: BurstGroupSignature,
        files: [BrowserFileItem],
        labels: [URL: String],
    ) async {
        let access = files.compactMap { CatalogAccess.shared.lease(for: $0.url) }
        defer { withExtendedLifetime(access) {} }
        let preparationFiles = deepAIReviewController.scope == .fast
            ? Array(files.prefix(8))
            : files
        var candidates: [DeepAIReviewInputCandidate] = []
        candidates.reserveCapacity(preparationFiles.count)

        for (index, file) in preparationFiles.enumerated() {
            guard !Task.isCancelled else { return }
            async let metadata = BrowserImageLoader.shared.metadata(for: file.url)
            async let thumbnail = BrowserImageLoader.shared.thumbnail(for: file.url, targetSize: 1024)
            let (loadedMetadata, loadedThumbnail) = await (metadata, thumbnail)
            let focusPoint = loadedMetadata?.focusPoint.map {
                CGPoint(x: CGFloat($0.normalizedX), y: CGFloat($0.normalizedY))
            }
            let sharpness = loadedThumbnail.flatMap {
                $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }.flatMap(WholeImageSharpnessScorer.score)
            candidates.append(DeepAIReviewInputCandidate(
                fileID: file.id,
                fileName: file.name,
                url: file.url,
                burstRank: index + 1,
                normalSharpnessScore: sharpness,
                subjectLabel: labels[file.url.standardizedFileURL],
                normalizedAFPoint: focusPoint,
            ))
        }

        await deepAIReviewController.start(
            groupID: groupID,
            groupSignature: groupSignature,
            candidates: candidates,
        )
    }
}
