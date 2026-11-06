import SwiftUI
import PhotoEvidenceContracts
import PhotoEvidenceUI

/// App composition boundary. The package itself never reads browser environments.
struct BrowserCloseUpsView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(FileBrowserViewModel.self) private var browser
    let model: CloseUpModel
    let renderer: BrowserCloseUpRenderer
    let onClose: () -> Void
    @State private var frames: [CloseUpFrame] = []

    var body: some View {
        CloseUpPanel(frames: frames, currentFrameID: selection.selectedFile?.url,
            model: model, renderer: renderer,
            onActivate: { frame in
                guard let file = selection.selectedFiles.first(where: { $0.url == frame.id }) else { return }
                browser.openZoom(for: file)
            }, onClose: onClose)
        .task(id: selection.selectedFiles) {
            let updated = await BrowserCloseUpFrameAdapter.frames(for: selection.selectedFiles)
            guard !Task.isCancelled else { return }
            frames = updated
        }
    }
}
