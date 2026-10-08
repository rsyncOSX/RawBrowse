import Foundation
import Observation

/// App-owned composition and cross-feature transitions shared by all scenes.
@Observable @MainActor
final class FileBrowserViewModel {
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
    @ObservationIgnored private var workspaceTask: Task<Void, Never>?

    init(
        settings: SettingsModel = SettingsModel(),
        downloads: ModelDownloadsModel = ModelDownloadsModel(),
        catalog: CatalogStore = CatalogStore(),
        contents: BrowserContentsModel = BrowserContentsModel(),
        raw9: RAW9EditingSession = RAW9EditingSession(),
    ) {
        settingsModel = settings
        self.downloads = downloads
        self.catalog = catalog
        self.contents = contents
        self.raw9 = raw9
        clip = CLIPFeatureModel(settings: settings)
        deepReview = DeepReviewModel()
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
            await downloads.refreshCLIPModels()
            await catalog.loadRememberedCatalogs()
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

    func addRootFolder(_ url: URL) {
        guard let folder = catalog.addRootFolder(url) else { return }
        clip.removeCatalog(at: url.standardizedFileURL)
        clip.catalogURLs = catalog.rootFolders.map { $0.url.standardizedFileURL }
        selectFolder(folder)
    }

    @discardableResult
    func selectFolder(_ folder: BrowserFolderItem) -> Bool {
        guard contents.isSidebarSelectionEnabled,
              catalog.startSecurityScopedAccess(for: catalog.securityScopedURL(for: folder.url)) else { return false }
        zoom.closeZoom()
        zoom.presentation.resetZoomInterfaceState()
        selection.clear()
        clip.clearSemanticSearchResults()
        contents.scan(folder, access: catalog.lease(for: folder.url))
        clip.selectCatalog(catalogAccessURL)
        return true
    }

    func startSimilaritySearch() {
        clip.startSimilaritySearch(anchor: selection.selectedFile)
    }

    func startDeepReview(groupID: Int, groupSignature: BurstGroupSignature, files: [BrowserFileItem]) async {
        let preparation = deepReview.deepAIReviewController.scope == .fast ? Array(files.prefix(8)) : files
        let access = files.compactMap { catalog.lease(for: $0.url) }
        defer { withExtendedLifetime(access) {} }
        let labels = await clip.classifySubjects(in: preparation.map(\.url))
        guard !Task.isCancelled else { return }
        await deepReview.startDeepReview(groupID: groupID, groupSignature: groupSignature, files: files, labels: labels)
    }

    func openZoom(for file: BrowserFileItem? = nil, initialZoomMode: BrowserZoomInitialMode = .fit,
                  showFocusPointOnOpen: Bool = false, preserveViewport: Bool = false)
    {
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
        clip.clearCatalogCLIPIndexes()
        zoom.closeZoom()
        contents.clear()
        selection.clear()
        clip.selectCatalog(nil)
        await catalog.clearRememberedCatalogs()
    }

    func removeRootCatalog(_ folder: BrowserFolderItem) async {
        let url = folder.url.standardizedFileURL
        if contents.selectedFolder?.url.standardizedFileURL.isEqualOrDescendant(of: url) == true {
            zoom.closeZoom()
            contents.clear()
            selection.clear()
            clip.selectCatalog(nil)
        }
        clip.removeCatalog(at: url)
        await catalog.removeRootCatalog(folder)
    }
}
