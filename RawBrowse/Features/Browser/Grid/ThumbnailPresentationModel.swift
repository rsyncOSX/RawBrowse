import AppKit
import Observation

nonisolated struct ThumbnailRequest: Hashable, Sendable {
    let url: URL
    let targetSize: Int
    let sourceFingerprint: String

    init(url: URL, targetSize: Int) {
        self.url = url
        self.targetSize = max(1, targetSize)
        sourceFingerprint = ImageSourceFingerprint.key(for: url)
    }
}

@Observable @MainActor
final class ThumbnailPresentationModel {
    private(set) var image: NSImage?
    private(set) var isLoading = false
    @ObservationIgnored private var request: ThumbnailRequest?
    @ObservationIgnored private var generation = UUID()

    func load(request: ThumbnailRequest, imageLoader: @MainActor () async -> NSImage?) async {
        guard !Task.isCancelled else { return }
        let diagnostic = BrowserPerformance.begin("thumbnail.presentationDelivery", request.url,
            details: ["target_pixels": String(request.targetSize)])
        var outcome = "superseded"
        defer { diagnostic?.end(Task.isCancelled ? "cancelled" : outcome) }
        let token = UUID()
        generation = token
        if self.request?.url != request.url || self.request?.sourceFingerprint != request.sourceFingerprint {
            image = nil
        }
        self.request = request
        isLoading = true
        defer {
            if generation == token { isLoading = false }
        }
        let result = await imageLoader()
        guard !Task.isCancelled, generation == token,
              ImageSourceFingerprint.key(for: request.url) == request.sourceFingerprint
        else { return }
        image = result
        outcome = result == nil ? "unavailable" : "image"
    }

    func invalidate() {
        generation = UUID()
        request = nil
        image = nil
        isLoading = false
    }
}
