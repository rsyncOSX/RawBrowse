import SwiftUI
import PhotoEvidenceContracts
import PhotoEvidenceUI

/// App composition boundary. The package itself never reads browser environments.
struct BrowserCloseUpsView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(FileBrowserViewModel.self) private var browser
    @Environment(ZoomModel.self) private var zoom
    @Environment(RAW9EditingSession.self) private var raw9
    @Environment(SettingsModel.self) private var settings
    let model: CloseUpModel
    let renderer: BrowserCloseUpRenderer
    let onClose: () -> Void
    @State private var frames: [CloseUpFrame] = []
    @State private var afPoints: [URL: CloseUpAFPointAvailability] = [:]
    @State private var sources: [URL: CloseUpRenderSource] = [:]
    @State private var planner = BrowserCloseUpSourcePlanner()
    @State private var preparationFailure: String?

    private var inputs: BrowserCloseUpRenderingInputs {
        var urls = Set(selection.selectedFiles.map(\.url))
        if let reference = model.reference { urls.insert(reference.id) }
        var live: [URL: RAW9Adjustments] = [:]
        for url in urls { live[url] = raw9.adjustmentsSnapshot(for: url) }
        return BrowserCloseUpRenderingInputs(files: selection.selectedFiles.map { BrowserCloseUpFile(url: $0.url, refreshRevision: $0.id) }, reference: model.reference,
            developRAW: zoom.useDevelopedRAW, bitDepth: settings.values.rawPreviewBitDepth, liveAdjustments: live)
    }

    var body: some View {
        let snapshot = inputs
        CloseUpPanel(frames: frames, currentFrameID: selection.selectedFile?.url,
            model: model, renderer: renderer, renderSources: sources, afPoints: afPoints,
            onActivate: { frame in
                guard let file = selection.selectedFiles.first(where: { $0.url == frame.id }) else { return }
                browser.openZoom(for: file)
            }, onUseAFPoint: { frame in
                if zoom.presentation.zoomOverlayVisible, zoom.file?.url == frame.id {
                    zoom.presentation.isZoomFocusPointVisible = true
                } else {
                    guard let file = selection.selectedFiles.first(where: { $0.url == frame.id }) else { return }
                    browser.openZoom(for: file, showFocusPointOnOpen: true)
                    zoom.presentation.isZoomFocusPointVisible = true
                }
            }, onClose: onClose)
        .overlay(alignment: .bottom) {
            if let preparationFailure {
                Text(preparationFailure).font(.caption).padding(8).background(.regularMaterial)
            }
        }
        .task(id: snapshot) {
            do {
                let plans = try await planner.prepare(snapshot)
                try Task.checkCancellation()
                let loadedAFPoints = try await BrowserCloseUpAFPoint.load(for: plans.map(\.frame))
                await renderer.configure(plans)
                try Task.checkCancellation()
                afPoints = loadedAFPoints
                sources = Dictionary(plans.map { ($0.frame.id, $0.source) }, uniquingKeysWith: { _, last in last })
                let selectedIDs = Set(snapshot.files.map(\.url))
                frames = plans.map(\.frame).filter { selectedIDs.contains($0.id) }
                if let reference = snapshot.reference, let updated = plans.first(where: { $0.frame.id == reference.id }) {
                    model.updateReference(updated.frame)
                }
                preparationFailure = nil
            } catch is CancellationError { return }
            catch { preparationFailure = error.localizedDescription }
        }
    }
}
