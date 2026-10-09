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
    var useDevelopedRAW = false
    var zoomImageError: String?
    var zoomImage: CGImage?
    var zoomExifInfo: RawImageMetadata?
    var isZoomExifInfoLoaded = false
    private(set) var isApplyingRAW9 = false
    @ObservationIgnored private var renderOperationID = UUID()
    @ObservationIgnored private var zoomTask: Task<Void, Never>?
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

    init(settings: SettingsModel, raw9: RAW9EditingSession) {
        settingsModel = settings
        self.raw9 = raw9
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
        file = selectedFile

        let shouldLoadSidecar = raw9.prepare(for: selectedFile.url)
        let initialAdjustments = raw9.raw9Adjustments
        zoomTask?.cancel()
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
        let previewSize = settingsModel.values.thumbnailSizeFullSize
        let access = CatalogAccess.shared.lease(for: selectedFile.url)
        zoomTask = Task {
            defer {
                withExtendedLifetime(access) {}
                if renderOperationID == operationID { isApplyingRAW9 = false }
            }
            guard !Task.isCancelled else { return }
            async let exifInfo = BrowserImageLoader.shared.metadata(for: selectedFile.url)
            do {
                let supportsRAW9 = await RAW9Support.isSupported(for: selectedFile.url)
                try Task.checkCancellation()
                if shouldLoadSidecar, supportsRAW9 {
                    try await raw9.restore(for: selectedFile.url, initialAdjustments: initialAdjustments)
                }
                try Task.checkCancellation()
                let adjustments = raw9.raw9Adjustments
                let developRAW = useDevelopedRAW && !SupportedFileType.isRenderedImage(selectedFile.url)
                let loadedImage: CGImage? = if developRAW {
                    if supportsRAW9 {
                        try await raw9.render(url: selectedFile.url, adjustments: adjustments, bitDepth: settingsModel.values.rawPreviewBitDepth)
                    } else {
                        try await BrowserImageLoader.shared.developedPreview(for: selectedFile.url)
                    }
                } else {
                    await BrowserImageLoader.shared.previewImage(
                        for: selectedFile.url, maxPixelSize: previewSize,
                    )
                }
                guard !Task.isCancelled else { return }
                zoomImage = loadedImage
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

    func refreshRAW9Preview() {
        guard presentation.zoomOverlayVisible, useDevelopedRAW,
              let url = file?.url, raw9.isEditing(url) else { return }
        let adjustments = raw9.raw9Adjustments
        let bitDepth = settingsModel.values.rawPreviewBitDepth
        zoomTask?.cancel()
        let operationID = UUID()
        renderOperationID = operationID
        isApplyingRAW9 = true
        let access = CatalogAccess.shared.lease(for: url)
        zoomTask = Task {
            defer {
                withExtendedLifetime(access) {}
                if renderOperationID == operationID { isApplyingRAW9 = false }
            }
            do {
                let image = try await raw9.render(url: url, adjustments: adjustments, bitDepth: bitDepth)
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
        zoomTask?.cancel()
        zoomTask = nil
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
