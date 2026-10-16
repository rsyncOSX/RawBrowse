import Foundation
import Observation

struct FolderAccessFailure {
    enum Operation { case select, refresh, addRoot }
    let folder: BrowserFolderItem
    let operation: Operation
    var message: String {
        "Could not access \(folder.url.path). Reconnect the drive or add the folder again to renew access."
    }
}

/// App-owned composition and cross-feature transitions shared by all scenes.
@Observable @MainActor
final class FileBrowserViewModel {
    private(set) var isShuttingDown = false
    private(set) var folderAccessFailure: FolderAccessFailure?
    let settingsModel: SettingsModel
    let downloads: ModelDownloadsModel
    let clip: CLIPFeatureModel
    let deepReview: DeepReviewModel
    let raw9: RAW9EditingSession
    let zoom: ZoomModel
    let catalog: CatalogStore
    let contents: BrowserContentsModel
    let selection: SelectionModel
    let sidebar: SidebarPresentationModel
    let browserPresentation = BrowserPresentationState()
    @ObservationIgnored private let refreshRunner = LatestTaskRunner()
    @ObservationIgnored private var workspaceTask: Task<Void, Never>?

    init(
        settings: SettingsModel = SettingsModel(),
        downloads: ModelDownloadsModel = ModelDownloadsModel(),
        catalog: CatalogStore = CatalogStore(),
        contents: BrowserContentsModel = BrowserContentsModel(),
        raw9: RAW9EditingSession = RAW9EditingSession(),
        deepReview: DeepReviewModel = DeepReviewModel(),
    ) {
        settingsModel = settings
        self.downloads = downloads
        self.catalog = catalog
        self.contents = contents
        self.raw9 = raw9
        clip = CLIPFeatureModel(settings: settings)
        self.deepReview = deepReview
        zoom = ZoomModel(settings: settings, raw9: raw9)
        selection = SelectionModel()
        sidebar = SidebarPresentationModel(catalog: catalog)
        clip.displayedFilesChanged = { [weak self] in self?.updateDisplayedFiles(selectFirst: true) }
        contents.filesChanged = { [weak self] in self?.updateDisplayedFiles() }
        contents.scanFinished = { [weak self] in self?.updateDisplayedFiles(selectFirst: true) }
        contents.childrenDiscovered = { [weak catalog] folder, children in
            catalog?.setLoadedChildren(children, for: folder)
        }
        clip.indexPresenceChanged = { [weak catalog] url, present in
            catalog?.setCLIPIndexPresence(present, for: url)
        }
        catalog.hierarchyChanged = { [weak self] in
            guard let self else { return }
            self.sidebar.hierarchyDidChange()
            self.clip.catalogURLs = self.catalog.rootFolders.map { $0.url.standardizedFileURL }
        }
        catalog.rootChildrenDiscovered = { [weak sidebar] folder in
            sidebar?.expandedFolderIDs.insert(folder.id)
        }
        catalog.folderChanged = { [weak contents] folder in
            if contents?.selectedFolder?.id == folder.id {
                contents?.selectedFolder = folder
            }
        }
        downloads.prepareForRemoval = { [weak self] id in
            guard let self else { return }
            switch id {
            case .clipDataComp:
                await deepReview.cancelAndWait()
                await clip.deactivateAndWait()

            case .sam3:
                await deepReview.deactivateAndWait()
            }
        }
        downloads.locationsChanged = { [weak self] locations in
            guard let self else { return }
            clip.activateModel(at: locations[settingsModel.values.selectedCLIPModel.downloadID])
            deepReview.activateModel(at: locations[.sam3])
        }
        sidebar.hierarchyDidChange()
        updateDisplayedFiles()
    }

    var canFindSimilar: Bool {
        selection.selectedFile != nil && clip.canSearch
    }

    var shouldPresentDeepReviewAction: Bool {
        !selection.selectedFileIDs.isEmpty && deepReview.sam3ModelStatus.isAvailable
    }

    var canDeepReviewSelection: Bool {
        shouldPresentDeepReviewAction && !deepReview.deepAIReviewController.isActionUnavailable
    }

    var catalogAccessURL: URL? {
        contents.selectedFolder.map { catalog.securityScopedURL(for: $0.url) }
    }

    private func updateDisplayedFiles(selectFirst: Bool = false) {
        selection.replaceDisplayedFiles(clip.semanticSearchActive ? clip.semanticFiles : contents.files,
                                        selectFirst: selectFirst)
    }

    func loadIfNeeded() async {
        if let workspaceTask {
            await workspaceTask.value; return
        }
        let task = Task { [self] in
            await settingsModel.loadSettings()
            await catalog.loadRememberedCatalogs()
            await downloads.refreshCLIPModels()
            for folder in catalog.rootFolders {
                clip.validateCatalogCLIPIndex(at: folder.url.standardizedFileURL)
            }
            if contents.selectedFolder == nil, let first = catalog.rootFolders.first {
                selectFolder(first)
            }
        }
        workspaceTask = task
        await task.value
    }

    func prepareForTermination(exports: RAW9ExportQueue = .shared) async -> String? {
        isShuttingDown = true
        await workspaceTask?.value
        await raw9.finishSaving()
        await exports.waitUntilFinished()
        await settingsModel.finishSaving()
        if settingsModel.hasUnsavedChanges {
            isShuttingDown = false
            return settingsModel.settingsError ?? "Some settings could not be saved."
        }
        if raw9.hasUnsavedChanges {
            isShuttingDown = false
            return raw9.raw9SidecarError ?? "Some image adjustments could not be saved."
        }
        // Prevent late download refreshes from reactivating a drained runtime.
        clip.cancelIndexing()
        deepReview.deepAIReviewController.cancel()
        await downloads.cancelAndWait()
        await deepReview.deactivateAndWait()
        await clip.deactivateAndWait()
        // Index completion may have persisted its final summary while we waited.
        await settingsModel.finishSaving()
        if settingsModel.hasUnsavedChanges {
            isShuttingDown = false
            await downloads.resumeAfterCancelledTermination()
            return settingsModel.settingsError ?? "Some settings could not be saved."
        }
        return nil
    }

    func addRootFolder(_ url: URL) {
        guard !isShuttingDown else { return }
        guard let folder = catalog.addRootFolder(url) else {
            folderAccessFailure = FolderAccessFailure(folder: BrowserFolderItem(url: url), operation: .addRoot)
            return
        }
        folderAccessFailure = nil
        clip.removeCatalog(at: url.standardizedFileURL)
        clip.catalogURLs = catalog.rootFolders.map { $0.url.standardizedFileURL }
        selectFolder(folder)
    }

    @discardableResult
    func selectFolder(_ folder: BrowserFolderItem) -> Bool {
        guard !isShuttingDown, contents.isSidebarSelectionEnabled,
              admitFolderAccess(folder, operation: .select) else { return false }
        refreshRunner.cancel()
        deepReview.deepAIReviewController.cancel()
        zoom.closeZoom()
        zoom.presentation.resetZoomInterfaceState()
        selection.clear()
        clip.clearSemanticSearchResults()
        contents.scan(folder, access: catalog.lease(for: folder.url))
        clip.selectCatalog(catalogAccessURL)
        return true
    }

    var canRefreshSelectedFolder: Bool {
        !isShuttingDown && contents.selectedFolder != nil && !contents.isScanning
    }

    @discardableResult
    func refreshSelectedFolder() -> Task<Void, Never>? {
        guard canRefreshSelectedFolder, let folder = contents.selectedFolder,
              admitFolderAccess(folder, operation: .refresh) else { return nil }
        let selectedURLs = Set(selection.selectedFiles.map { $0.url.standardizedFileURL })
        let primaryURL = selection.selectedFile?.url.standardizedFileURL
        deepReview.deepAIReviewController.cancel()
        zoom.closeZoom()
        clip.clearSemanticSearchResults()
        let scan = contents.scan(folder, access: catalog.lease(for: folder.url))
        clip.validateCatalogCLIPIndex(at: folder.url.standardizedFileURL)
        return refreshRunner.start { [self] token in
            await scan.value
            guard !Task.isCancelled, refreshRunner.isCurrent(token),
                  contents.selectedFolder?.id == folder.id, contents.scanError == nil,
                  !clip.semanticSearchActive else { return }
            let surviving = selection.displayedFiles.filter { selectedURLs.contains($0.url.standardizedFileURL) }
            selection.selectedFileIDs = Set(surviving.map(\.id))
            selection.selectedFileID = surviving.first(where: { $0.url.standardizedFileURL == primaryURL })?.id
                ?? surviving.first?.id
        }
    }

    private func admitFolderAccess(_ folder: BrowserFolderItem, operation: FolderAccessFailure.Operation) -> Bool {
        guard catalog.startSecurityScopedAccess(for: catalog.securityScopedURL(for: folder.url)) else {
            folderAccessFailure = FolderAccessFailure(folder: folder, operation: operation)
            return false
        }
        folderAccessFailure = nil
        return true
    }

    func dismissFolderAccessFailure() {
        folderAccessFailure = nil
    }

    func retryFolderAccess() {
        guard let failure = folderAccessFailure else { return }
        switch failure.operation {
        case .addRoot:
            addRootFolder(failure.folder.url)
        case .refresh where contents.selectedFolder?.id == failure.folder.id:
            refreshSelectedFolder()
        case .select, .refresh:
            selectFolder(failure.folder)
        }
    }

    func startSimilaritySearch() {
        clip.startSimilaritySearch(anchor: selection.selectedFile)
    }

    func startDeepReview(groupID: Int, groupSignature: BurstGroupSignature, files: [BrowserFileItem]) async {
        let access = files.compactMap { catalog.lease(for: $0.url) }
        defer { withExtendedLifetime(access) {} }
        await deepReview.startDeepReview(groupID: groupID, groupSignature: groupSignature, files: files) { [clip] urls in
            await clip.classifySubjects(in: urls)
        }
    }

    func openZoom(for file: BrowserFileItem? = nil, initialZoomMode: BrowserZoomInitialMode = .fit,
                  showFocusPointOnOpen: Bool = false, preserveViewport: Bool = false) {
        if let file {
            selection.selectedFileID = file.id
        }
        guard let selectedFile = selection.selectedFile else { return }
        zoom.openZoom(for: selectedFile, initialZoomMode: initialZoomMode,
                      showFocusPointOnOpen: showFocusPointOnOpen, preserveViewport: preserveViewport)
    }

    func navigateSelection(by delta: Int) {
        guard let next = selection.navigateSelection(by: delta) else { return }
        if zoom.presentation.zoomOverlayVisible {
            openZoom(for: next, initialZoomMode: zoom.presentation.zoomLaunchContext.initialZoomMode,
                     showFocusPointOnOpen: zoom.presentation.zoomLaunchContext.showFocusPointOnOpen)
        }
    }

    func clearRememberedCatalogs() async {
        folderAccessFailure = nil
        deepReview.deepAIReviewController.cancel()
        refreshRunner.cancel()
        clip.clearCatalogCLIPIndexes()
        zoom.closeZoom()
        contents.clear()
        selection.clear()
        clip.selectCatalog(nil)
        await catalog.clearRememberedCatalogs()
    }

    func removeRootCatalog(_ folder: BrowserFolderItem) async {
        deepReview.deepAIReviewController.cancel()
        let url = folder.url.standardizedFileURL
        if folderAccessFailure?.folder.url.standardizedFileURL.isEqualOrDescendant(of: url) == true {
            folderAccessFailure = nil
        }
        if contents.selectedFolder?.url.standardizedFileURL.isEqualOrDescendant(of: url) == true {
            refreshRunner.cancel()
            zoom.closeZoom()
            contents.clear()
            selection.clear()
            clip.selectCatalog(nil)
        }
        clip.removeCatalog(at: url)
        await catalog.removeRootCatalog(folder)
    }
}
