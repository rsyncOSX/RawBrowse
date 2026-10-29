import CoreGraphics
import Foundation
import Observation
import RawParserKit

@Observable @MainActor
final class ZoomModel {
    let settingsModel: SettingsModel
    let raw9: RAW9EditingSession
    let presentation = ZoomPresentationState()
    private(set) var file: BrowserFileItem?
    private(set) var raw9SupportedURL: URL?
    var useDevelopedRAW = false
    // A bounded fallback is used until the overlay reports its actual backing-pixel size.
    private var fitPreviewDimension: CGFloat = 2560
    private var needsNativeRAWPreview = false
    var rawPreviewMaximumDimension: CGFloat? { needsNativeRAWPreview ? nil : fitPreviewDimension }

    func updateRAWPreviewViewport(size: CGSize, displayScale: CGFloat, zoomScale: CGFloat) {
        guard size.width > 0, size.height > 0, displayScale > 0 else { return }
        let previous = rawPreviewMaximumDimension
        // Bucket resize events to avoid a new expensive render for every window pixel.
        fitPreviewDimension = ceil(max(size.width, size.height) * displayScale / 256) * 256
        needsNativeRAWPreview = zoomScale > 1
        guard previous != rawPreviewMaximumDimension, zoomImage != nil, !isApplyingRAW9,
              isZoomExifInfoLoaded else { return }
        refreshRAW9Preview()
    }

    var zoomImageError: String?
    var zoomImage: CGImage?
    var zoomExifInfo: RawImageMetadata?
    var isZoomExifInfoLoaded = false
    private(set) var isApplyingRAW9 = false
    @ObservationIgnored private var renderOperationID = UUID()
    @ObservationIgnored private var isOpeningZoom = false
    @ObservationIgnored private var zoomTask: Task<Void, Never>?
    @ObservationIgnored private let imageLoader: BrowserImageLoader
    @ObservationIgnored private let renderRAWPreview: @MainActor (URL, RAW9Adjustments, RAWPreviewBitDepth, CGFloat?) async throws -> CGImage
    @ObservationIgnored private let supportsRAW9: @Sendable (URL) async -> Bool
    var rawPreviewBitDepth: RAWPreviewBitDepth {
        get { settingsModel.values.rawPreviewBitDepth }
        set {
            guard settingsModel.values.rawPreviewBitDepth != newValue else { return }
            settingsModel.values.rawPreviewBitDepth = newValue
            settingsModel.persistSettings()
            if presentation.zoomOverlayVisible, useDevelopedRAW, raw9.hasRestored(file?.url) {
                refreshRAW9Preview()
            }
        }
    }

    init(settings: SettingsModel, raw9: RAW9EditingSession,
         imageLoader: BrowserImageLoader = .shared,
         supportsRAW9: @escaping @Sendable (URL) async -> Bool = { await RAW9Support.isSupported(for: $0) },
         renderRAWPreview: (@MainActor (URL, RAW9Adjustments, RAWPreviewBitDepth, CGFloat?) async throws -> CGImage)? = nil) {
        settingsModel = settings
        self.raw9 = raw9
        self.imageLoader = imageLoader
        self.supportsRAW9 = supportsRAW9
        self.renderRAWPreview = renderRAWPreview ?? { url, adjustments, bitDepth, maximumDimension in
            try await raw9.render(url: url, adjustments: adjustments, bitDepth: bitDepth, maximumDimension: maximumDimension)
        }
    }

    func pasteRAW9Adjustments() {
        guard raw9.pasteRAW9Adjustments() else { return }
        useDevelopedRAW = true
        refreshRAW9Preview()
    }

    func openZoom(
        for selectedFile: BrowserFileItem,
        initialZoomMode: BrowserZoomInitialMode = .fit,
        showFocusPointOnOpen: Bool = false,
        preserveViewport: Bool = false,
    ) {
        needsNativeRAWPreview = initialZoomMode == .actualPixels || presentation.zoomScale > 1
        file = selectedFile
        raw9SupportedURL = nil

        zoomTask?.cancel()
        isOpeningZoom = true
        let operationID = UUID()
        renderOperationID = operationID
        isApplyingRAW9 = useDevelopedRAW
        if !preserveViewport {
            zoomImage = nil
        }
        zoomImageError = nil
        zoomExifInfo = nil
        isZoomExifInfoLoaded = false
        if !preserveViewport {
            presentation.zoomLaunchContext = BrowserZoomLaunchContext(
                initialZoomMode: initialZoomMode,
                showFocusPointOnOpen: showFocusPointOnOpen,
            )
        }
        presentation.zoomOverlayVisible = true
        let cacheSettings = settingsModel.values
        let access = CatalogAccess.shared.lease(for: selectedFile.url)
        zoomTask = Task {
            var renderedDimension = rawPreviewMaximumDimension
            var renderedAdjustments: RAW9Adjustments?
            var renderedBitDepth = settingsModel.values.rawPreviewBitDepth
            let diagnostic = BrowserPerformance.begin("preview.presentationDelivery", selectedFile.url,
                details: ["target_pixels": rawPreviewMaximumDimension.map { String(Int($0)) } ?? "native"])
            var delivered = false
            defer { if !delivered { diagnostic?.end(Task.isCancelled ? "cancelled" : "failed") } }
            defer {
                withExtendedLifetime(access) {}
                if renderOperationID == operationID {
                    isOpeningZoom = false
                    isApplyingRAW9 = false
                    if !Task.isCancelled, raw9SupportedURL == selectedFile.url,
                       let renderedAdjustments,
                       renderedDimension != rawPreviewMaximumDimension
                        || renderedAdjustments != raw9.raw9Adjustments
                        || renderedBitDepth != settingsModel.values.rawPreviewBitDepth {
                        refreshRAW9Preview()
                    }
                }
            }
            guard !Task.isCancelled else { return }
            async let exifInfo = imageLoader.metadata(for: selectedFile.url)
            let developRAW = useDevelopedRAW && !SupportedFileType.isRenderedImage(selectedFile.url)
            do {
                let loadedImage: CGImage?
                if developRAW {
                    // Decoder probing and editing state are lazy: JPG navigation never needs them.
                    let shouldLoadSidecar = raw9.prepare(for: selectedFile.url)
                    let initialAdjustments = raw9.raw9Adjustments
                    if try await prepareRAW9(for: selectedFile.url, shouldLoadSidecar: shouldLoadSidecar,
                                             initialAdjustments: initialAdjustments) {
                        renderedDimension = rawPreviewMaximumDimension
                        renderedAdjustments = raw9.raw9Adjustments
                        renderedBitDepth = settingsModel.values.rawPreviewBitDepth
                        loadedImage = try await renderRAWPreview(selectedFile.url, raw9.raw9Adjustments,
                                                               renderedBitDepth, renderedDimension)
                    } else {
                        loadedImage = try await imageLoader.developedPreview(for: selectedFile.url)
                    }
                } else {
                    await imageLoader.apply(settings: cacheSettings)
                    loadedImage = await imageLoader.previewImage(for: selectedFile.url)
                }
                guard !Task.isCancelled else { return }
                zoomImage = loadedImage
                diagnostic?.end(loadedImage == nil ? "unavailable" : "image")
                delivered = true
                if loadedImage == nil {
                    zoomImageError = "Unable to load this image."
                }
            } catch {
                guard !Task.isCancelled else { return }
                zoomImageError = "RAW development failed: \(error.localizedDescription)"
            }
            let loadedExifInfo = await exifInfo
            guard !Task.isCancelled else { return }
            zoomExifInfo = loadedExifInfo
            isZoomExifInfoLoaded = true
        }
    }

    private func prepareRAW9(for url: URL, shouldLoadSidecar: Bool,
                             initialAdjustments: RAW9Adjustments) async throws -> Bool {
        let probe = BrowserPerformance.begin("preview.raw9Support", url)
        let supported = await supportsRAW9(url)
        probe?.end(supported ? "supported" : "unsupported")
        try Task.checkCancellation()
        if shouldLoadSidecar, supported {
            let restoration = BrowserPerformance.begin("preview.raw9Sidecar", url)
            defer { restoration?.end(Task.isCancelled ? "cancelled" : "finished") }
            try await raw9.restore(for: url, initialAdjustments: initialAdjustments)
        }
        try Task.checkCancellation()
        // Publish only after restoration, so RAW controls use the selected file's state.
        raw9SupportedURL = supported ? url : nil
        return supported
    }

    func refreshRAW9Preview() {
        guard presentation.zoomOverlayVisible, useDevelopedRAW,
              let url = file?.url, raw9.isEditing(url) else { return }
        // Restoration and viewport changes must not cancel the initial image/metadata load.
        // Its completion compares the rendered inputs with the latest requested inputs.
        guard !isOpeningZoom else { return }
        let adjustments = raw9.raw9Adjustments
        let bitDepth = settingsModel.values.rawPreviewBitDepth
        let maximumDimension = rawPreviewMaximumDimension
        zoomTask?.cancel()
        let operationID = UUID()
        renderOperationID = operationID
        isApplyingRAW9 = true
        let access = CatalogAccess.shared.lease(for: url)
        zoomTask = Task {
            defer {
                withExtendedLifetime(access) {}
                if renderOperationID == operationID {
                    isApplyingRAW9 = false
                    if !Task.isCancelled, maximumDimension != rawPreviewMaximumDimension {
                        refreshRAW9Preview()
                    }
                }
            }
            do {
                let image = try await renderRAWPreview(url, adjustments, bitDepth, maximumDimension)
                guard !Task.isCancelled, file?.url == url, useDevelopedRAW else { return }
                zoomImage = image
                zoomImageError = nil
            } catch {
                guard !Task.isCancelled, file?.url == url else { return }
                zoomImageError = "RAW development failed: \(error.localizedDescription)"
            }
        }
    }

    func closeZoom() {
        raw9.close()
        file = nil
        raw9SupportedURL = nil
        zoomTask?.cancel()
        zoomTask = nil
        isOpeningZoom = false
        renderOperationID = UUID()
        isApplyingRAW9 = false
        presentation.zoomOverlayVisible = false
        zoomImage = nil
        zoomImageError = nil
        zoomExifInfo = nil
        isZoomExifInfoLoaded = false
        presentation.zoomLaunchContext = .default
    }
}
