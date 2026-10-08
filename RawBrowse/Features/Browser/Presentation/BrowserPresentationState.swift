import Observation

@Observable @MainActor
final class BrowserPresentationState {
    var isShowingFolderPicker = false
    var isShowingClearCatalogConfirmation = false
}
