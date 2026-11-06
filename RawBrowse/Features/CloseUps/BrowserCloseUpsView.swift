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
        CloseUpPanel(frames: frames, currentFrameID: selection.selectedFile?.url,
            model: model, renderer: renderer, renderSources: sources,
            onActivate: { frame in
                guard let file = selection.selectedFiles.first(where: { $0.url == frame.id }) else { return }
                browser.openZoom(for: file)
            }, onClose: onClose)
        .overlay(alignment: .bottom) {
            if let preparationFailure {
                Text(preparationFailure).font(.caption).padding(8).background(.regularMaterial)
            }
        }
        .task(id: inputs) {
            let snapshot = inputs
            do {
                let plans = try await planner.prepare(snapshot)
                try Task.checkCancellation()
                await renderer.configure(plans)
                try Task.checkCancellation()
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
