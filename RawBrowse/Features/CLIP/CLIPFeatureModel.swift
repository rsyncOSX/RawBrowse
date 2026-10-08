import CoreAICLIPBackend
import Foundation
import Observation

@Observable @MainActor
final class CLIPFeatureModel {
    let settingsModel: SettingsModel
    private(set) var catalogURL: URL?
    var catalogURLs: [URL] = []
    @ObservationIgnored var displayedFilesChanged: (@MainActor () -> Void)?
    @ObservationIgnored var indexPresenceChanged: (@MainActor (URL, Bool) -> Void)?
    var clipModelStatus: CLIPModelStatus = .notConfigured
    var clipIndexStatus: CLIPIndexStatus = .noFolderSelected
    var isIndexing = false
    var indexingProgress: CLIPIndexingProgress?
    var lastIndexSummary: CLIPIndexSummary?
    var semanticSearchQuery = ""
    var semanticSearchResults: [CLIPSearchResult] = []
    var semanticSearchActive = false
    var similaritySearchAnchorName: String?
    var isSearching = false
    var hasCompatibleCLIPIndex = false
    var clipFeatureError: String?
    @ObservationIgnored private var activeCLIPModelURL: URL?
    @ObservationIgnored private let clipModelManager = CLIPModelManager()
    @ObservationIgnored private var clipProvider: CoreAICLIPProvider?
    @ObservationIgnored private var clipEngine: CLIPSearchEngine?
    @ObservationIgnored private var clipEngineDirectoryURL: URL?
    @ObservationIgnored private var modelValidationTask: Task<Void, Never>?
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var indexValidationTask: Task<Void, Never>?
    @ObservationIgnored private var catalogCLIPIndexes: [URL: (engine: CLIPSearchEngine, status: CLIPIndexStatus)] = [:]
    @ObservationIgnored private var catalogIndexValidationTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let searchRunner = LatestTaskRunner()
    private(set) var semanticFiles: [BrowserFileItem] = []
    @ObservationIgnored private var indexingID = UUID()
    @ObservationIgnored private var indexValidationID = UUID()
    var isShowingSemanticResults: Bool {
        semanticSearchActive
    }

    var isShowingSimilarityResults: Bool {
        similaritySearchAnchorName != nil
    }

    var activeCLIPModelName: String {
        guard case let .available(_, _, modelName) = clipModelStatus else {
            return settingsModel.values.selectedCLIPModel.displayName
        }
        return modelName
    }

    var semanticSearchLimit: Int {
        settingsModel.values.semanticSearchLimit
    }

    var canIndexSelectedFolder: Bool {
        catalogURL != nil
            && clipProvider != nil
            && !isIndexing
            && !isSearching
    }

    var canSearch: Bool {
        hasCompatibleCLIPIndex
            && clipEngine != nil
            && !isIndexing
            && !isSearching
    }

    init(settings: SettingsModel) {
        settingsModel = settings
    }

    func selectCatalog(_ url: URL?) {
        catalogURL = url?.standardizedFileURL
        if let catalogURL {
            useCatalogCLIPIndex(at: catalogURL)
        } else {
            resetCLIPIndexSelection()
        }
    }

    func removeCatalog(at url: URL) {
        catalogIndexValidationTasks.removeValue(forKey: url)?.cancel()
        catalogCLIPIndexes.removeValue(forKey: url)
        catalogURLs.removeAll { $0 == url }
    }

    func classifySubjects(in urls: [URL]) async -> [URL: String] {
        await (try? clipEngine?.classifySubjects(in: urls)) ?? [:]
    }

    func activateModel(at selectedURL: URL?) {
        guard let modelURL = selectedURL else {
            deactivateCLIPModelRuntime()
            return
        }

        let standardizedURL = modelURL.standardizedFileURL
        let isCurrentModelReady = activeCLIPModelURL == standardizedURL && clipProvider != nil
        let isCurrentModelBeingValidated = activeCLIPModelURL == standardizedURL
            && modelValidationTask != nil
        guard !isCurrentModelReady, !isCurrentModelBeingValidated else { return }

        validateCLIPModel(at: standardizedURL)
    }

    func adjustSemanticSearchLimit(by delta: Int) {
        let adjusted = min(max(settingsModel.values.semanticSearchLimit + delta, 10), 500)
        guard adjusted != settingsModel.values.semanticSearchLimit else { return }
        settingsModel.values.semanticSearchLimit = adjusted
        settingsModel.persistSettings()
        if !semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           hasCompatibleCLIPIndex {
            startSemanticSearch()
        }
    }

    func startIndexingSelectedFolder() {
        guard let directory = catalogURL,
              let provider = clipProvider
        else {
            clipFeatureError = CLIPFeatureError.modelNotConfigured.description
            return
        }

        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        indexingProgress = nil
        indexValidationTask?.cancel()
        searchRunner.cancel()
        let operationID = UUID()
        indexingID = operationID
        indexValidationID = UUID()
        let engine = makeCLIPEngine(provider: provider, directory: directory)
        clipEngine = engine
        clipEngineDirectoryURL = directory
        hasCompatibleCLIPIndex = false
        clipIndexStatus = .checking(directory)
        isIndexing = true
        indexingProgress = nil
        lastIndexSummary = nil
        clipFeatureError = nil
        clearSemanticSearchResults(keepingQuery: true)

        let access = CatalogAccess.shared.lease(for: directory)
        indexingTask = Task { [self] in
            defer { withExtendedLifetime(access) {} }
            do {
                let summary = try await engine.synchronize(directory: directory) { [weak self] progress in
                    await self?.publishIndexingProgress(progress, operationID: operationID)
                }
                try Task.checkCancellation()
                guard self.indexingID == operationID else { return }
                self.lastIndexSummary = summary
                self.settingsModel.values.lastIndexedDirectoryPath = directory.path
                self.settingsModel.persistSettings()
            } catch is CancellationError {
                // Cancellation is user initiated or caused by a replacement index operation.
            } catch {
                guard !Task.isCancelled, self.indexingID == operationID else { return }
                self.clipFeatureError = String(describing: error)
            }
            guard self.indexingID == operationID else { return }
            self.isIndexing = false
            self.indexingProgress = nil
            self.indexingTask = nil
            self.validateSelectedFolderCLIPIndex()
        }
    }

    func cancelIndexing() {
        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        isIndexing = false
        indexingProgress = nil
        validateSelectedFolderCLIPIndex()
    }

    func validateSelectedFolderCLIPIndex() {
        guard let directory = catalogURL else {
            clipIndexStatus = .noFolderSelected
            hasCompatibleCLIPIndex = false
            return
        }
        validateCatalogCLIPIndex(at: directory)
    }

    func validateCatalogCLIPIndex(at directory: URL) {
        guard let provider = clipProvider else {
            if catalogURL == directory {
                clipIndexStatus = .modelRequired
                hasCompatibleCLIPIndex = false
            }
            return
        }
        catalogIndexValidationTasks[directory]?.cancel()
        let engine = makeCLIPEngine(provider: provider, directory: directory)
        catalogCLIPIndexes[directory] = (engine, .checking(directory))
        if catalogURL == directory {
            useCatalogCLIPIndex(at: directory)
        }
        let access = CatalogAccess.shared.lease(for: directory)
        let task = Task { [weak self] in
            defer { withExtendedLifetime(access) {} }
            let status = await engine.validateIndex(directory: directory)
            guard let self, !Task.isCancelled else { return }
            self.catalogCLIPIndexes[directory] = (engine, status)
            if let indexFileExists = status.indexFileExists {
                self.indexPresenceChanged?(directory, indexFileExists)
            }
            if self.catalogURL == directory {
                self.useCatalogCLIPIndex(at: directory)
                if status.allowsSearch {
                    self.settingsModel.values.lastIndexedDirectoryPath = directory.path
                    self.settingsModel.persistSettings()
                } else {
                    self.clearSemanticSearchResults(keepingQuery: true)
                }
            }
            self.catalogIndexValidationTasks[directory] = nil
            if self.catalogURL == directory {
                self.indexValidationTask = nil
            }
        }
        catalogIndexValidationTasks[directory] = task
        if catalogURL == directory {
            indexValidationTask = task
        }
    }

    private func useCatalogCLIPIndex(at directory: URL) {
        guard let cached = catalogCLIPIndexes[directory] else {
            validateCatalogCLIPIndex(at: directory)
            return
        }
        clipEngine = cached.engine
        clipEngineDirectoryURL = directory
        clipIndexStatus = cached.status
        hasCompatibleCLIPIndex = cached.status.allowsSearch
        indexValidationTask = catalogIndexValidationTasks[directory]
    }

    func clearCatalogCLIPIndexes() {
        for task in catalogIndexValidationTasks.values {
            task.cancel()
        }
        catalogIndexValidationTasks.removeAll()
        catalogCLIPIndexes.removeAll()
    }

    func startSemanticSearch() {
        let query = semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSemanticSearchResults()
            return
        }
        guard let engine = clipEngine, hasCompatibleCLIPIndex else {
            clipFeatureError = CLIPFeatureError.missingCompatibleIndex.description
            return
        }

        startSearch(anchorName: nil) { limit in
            try await engine.search(text: query, limit: limit)
        }
    }

    func startSimilaritySearch(anchor: BrowserFileItem?) {
        guard let anchor else { return }
        guard let engine = clipEngine, hasCompatibleCLIPIndex else {
            clipFeatureError = CLIPFeatureError.missingCompatibleIndex.description
            return
        }
        startSearch(anchorName: anchor.name) { limit in
            try await engine.search(similarTo: anchor.url, limit: limit)
        }
    }

    @discardableResult
    func startSearch(
        anchorName: String?,
        operation: @escaping @MainActor (Int) async throws -> [CLIPSearchResult],
    ) -> Task<Void, Never> {
        isSearching = true
        clipFeatureError = nil
        semanticSearchActive = true
        similaritySearchAnchorName = anchorName
        semanticSearchResults = []
        semanticFiles = []
        let limit = settingsModel.values.semanticSearchLimit
        let access = catalogURL.flatMap { CatalogAccess.shared.lease(for: $0) }
        return searchRunner.start { [self] token in
            defer { withExtendedLifetime(access) {} }
            defer {
                if searchRunner.isCurrent(token) {
                    isSearching = false
                }
            }
            do {
                let results = try await operation(limit)
                guard !Task.isCancelled, searchRunner.isCurrent(token) else { return }
                semanticSearchResults = results
                semanticFiles = results.map { BrowserFileItem(url: $0.url) }
                displayedFilesChanged?()
            } catch is CancellationError {
                // A newer search owns publication.
            } catch {
                guard !Task.isCancelled, searchRunner.isCurrent(token) else { return }
                clipFeatureError = error.localizedDescription
                clearSemanticSearchResults(keepingQuery: true)
            }
        }
    }

    func clearSemanticSearchResults(keepingQuery: Bool = false) {
        searchRunner.cancel()
        isSearching = false
        semanticSearchResults = []
        semanticSearchActive = false
        similaritySearchAnchorName = nil
        semanticFiles = []
        if !keepingQuery {
            semanticSearchQuery = ""
        }
        displayedFilesChanged?()
    }

    private func deactivateCLIPModelRuntime() {
        clearCatalogCLIPIndexes()
        activeCLIPModelURL = nil
        modelValidationTask?.cancel()
        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        indexingProgress = nil
        indexValidationTask?.cancel()
        searchRunner.cancel()
        clipModelStatus = .notConfigured
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = catalogURL == nil ? .noFolderSelected : .modelRequired
        isIndexing = false
        isSearching = false
        clearSemanticSearchResults()
    }

    private func validateCLIPModel(at url: URL) {
        clearCatalogCLIPIndexes()
        let url = url.standardizedFileURL
        activeCLIPModelURL = url
        modelValidationTask?.cancel()
        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        indexingProgress = nil
        indexValidationTask?.cancel()
        searchRunner.cancel()
        indexValidationID = UUID()
        clipModelStatus = .checking(url)
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = catalogURL == nil ? .noFolderSelected : .modelRequired
        isIndexing = false
        isSearching = false
        clipFeatureError = nil
        clearSemanticSearchResults()

        modelValidationTask = Task { [self] in
            let load = await self.clipModelManager.load(url: url)
            guard !Task.isCancelled, self.activeCLIPModelURL == url else { return }
            self.clipModelStatus = load.status
            self.clipProvider = load.provider
            for directory in self.catalogURLs {
                self.validateCatalogCLIPIndex(at: directory)
            }
            if let directory = self.catalogURL {
                self.useCatalogCLIPIndex(at: directory)
            } else if let provider = load.provider,
                      let directoryPath = self.settingsModel.values.lastIndexedDirectoryPath {
                await self.restoreCLIPEngine(
                    provider: provider,
                    directory: URL(filePath: directoryPath),
                    modelURL: url,
                )
            }
            guard !Task.isCancelled, self.activeCLIPModelURL == url else { return }
            self.modelValidationTask = nil
        }
    }

    private func restoreCLIPEngine(
        provider: CoreAICLIPProvider,
        directory: URL,
        modelURL: URL,
    ) async {
        let standardizedDirectory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardizedDirectory.path,
            isDirectory: &isDirectory,
        ), isDirectory.boolValue else { return }
        let engine = makeCLIPEngine(provider: provider, directory: standardizedDirectory)
        guard await engine.hasCompatibleIndex(),
              !Task.isCancelled, activeCLIPModelURL == modelURL, catalogURL == nil else { return }
        let status = await engine.validateIndex(directory: standardizedDirectory)
        guard !Task.isCancelled, activeCLIPModelURL == modelURL, catalogURL == nil else { return }
        clipEngine = engine
        clipEngineDirectoryURL = standardizedDirectory
        clipIndexStatus = status
        hasCompatibleCLIPIndex = status.allowsSearch
    }

    private func makeCLIPEngine(
        provider: CoreAICLIPProvider,
        directory: URL,
    ) -> CLIPSearchEngine {
        let indexURL = CLIPIndexPaths.defaultIndexURL(
            directory: directory,
            modelFingerprint: provider.backendDescriptor.modelFingerprint,
        )
        return CLIPSearchEngine(
            provider: provider,
            indexStore: CLIPIndexStore(fileURL: indexURL),
            concurrencyLimit: 1,
        )
    }

    private func publishIndexingProgress(
        _ progress: CLIPIndexingProgress,
        operationID: UUID,
    ) {
        guard indexingID == operationID else { return }
        indexingProgress = progress
    }

    func resetCLIPIndexSelection() {
        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        indexingProgress = nil
        indexValidationTask?.cancel()
        searchRunner.cancel()
        indexValidationID = UUID()
        clipEngine = nil
        clipEngineDirectoryURL = nil
        clipIndexStatus = .noFolderSelected
        hasCompatibleCLIPIndex = false
        isIndexing = false
        indexingProgress = nil
        clearSemanticSearchResults()
    }
}
