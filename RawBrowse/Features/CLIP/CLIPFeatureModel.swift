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
    private(set) var isIndexing = false
    private(set) var isCancellingIndex = false
    var indexingProgress: CLIPIndexingProgress?
    private(set) var indexingDirectoryURL: URL?
    private var indexSummaries: [URL: CLIPIndexSummary] = [:]
    var lastIndexSummary: CLIPIndexSummary? {
        catalogURL.flatMap { indexSummaries[$0] }
    }

    var semanticSearchQuery = ""
    var semanticSearchResults: [CLIPSearchResult] = []
    var semanticSearchActive = false
    var similaritySearchAnchorName: String?
    var isSearching = false
    var hasCompatibleCLIPIndex = false
    var clipFeatureError: String?
    private var isRuntimeSuspended = false
    @ObservationIgnored private var runtimeTasks: [UUID: Task<Void, Never>] = [:]
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
        !isRuntimeSuspended && catalogURL != nil
            && clipProvider != nil
            && !isIndexing
            && !isSearching
    }

    var canSearch: Bool {
        !isRuntimeSuspended && hasCompatibleCLIPIndex
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
        indexSummaries.removeValue(forKey: url)
        catalogURLs.removeAll { $0 == url }
    }

    func classifySubjects(in urls: [URL]) async -> [URL: String] {
        guard !isRuntimeSuspended, !isIndexing, let engine = clipEngine else { return [:] }
        var labels: [URL: String] = [:]
        let task = trackRuntimeTask {
            labels = await (try? engine.classifySubjects(in: urls)) ?? [:]
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? [:] : labels
    }

    func activateModel(at selectedURL: URL?) {
        isRuntimeSuspended = false
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
        guard !isRuntimeSuspended, !isIndexing else { return }
        guard let directory = catalogURL,
              let provider = clipProvider
        else {
            clipFeatureError = CLIPFeatureError.modelNotConfigured.description
            return
        }

        cancelIndexing()
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
        let access = CatalogAccess.shared.lease(for: directory)
        beginIndexing(directory: directory, operationID: operationID) { [self] in
            defer { withExtendedLifetime(access) {} }
            return try await engine.synchronize(directory: directory) { [weak self] progress in
                await self?.publishIndexingProgress(progress, operationID: operationID)
            }
        }
    }

    /// Own the writer until it exits, even when a runtime transition cancels it.
    @discardableResult
    func beginIndexing(
        directory: URL,
        operationID: UUID = UUID(),
        operation: @escaping @MainActor () async throws -> CLIPIndexSummary,
    ) -> Task<Void, Never>? {
        guard !isRuntimeSuspended, indexingTask == nil else { return nil }
        indexingID = operationID
        isIndexing = true
        isCancellingIndex = false
        indexingProgress = nil
        indexingDirectoryURL = directory
        clipFeatureError = nil
        clearSemanticSearchResults(keepingQuery: true)
        // Include replaced/cancelled readers still unwinding, not just the
        // validation handles currently visible in the catalog cache.
        let readers = Array(runtimeTasks.values)
        readers.forEach { $0.cancel() }
        indexingTask = trackRuntimeTask { [self] in
            defer {
                isIndexing = false
                isCancellingIndex = false
                indexingProgress = nil
                indexingTask = nil
                indexingDirectoryURL = nil
                if !isRuntimeSuspended, clipProvider != nil {
                    validateCatalogCLIPIndex(at: directory)
                }
            }
            do {
                for reader in readers { await reader.value }
                await searchRunner.cancelAndWait()
                try Task.checkCancellation()
                let summary = try await operation()
                try Task.checkCancellation()
                guard indexingID == operationID else { return }
                recordIndexSummary(summary, for: directory)
            } catch is CancellationError {
                // Ownership is released only by the cleanup above.
            } catch {
                guard !Task.isCancelled, indexingID == operationID else { return }
                clipFeatureError = String(describing: error)
            }
        }
        return indexingTask
    }

    func recordIndexSummary(_ summary: CLIPIndexSummary, for directory: URL) {
        indexSummaries[directory.standardizedFileURL] = summary
        settingsModel.values.lastIndexedDirectoryPath = directory.path
        settingsModel.persistSettings()
    }

    func cancelIndexing() {
        // Keep ownership until the worker exits, including non-cooperative inference.
        guard let indexingTask else { return }
        isCancellingIndex = true
        indexingTask.cancel()
        indexingProgress = nil
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
        guard !isRuntimeSuspended else { return }
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
        let writer = indexingTask
        let task = trackRuntimeTask { [weak self] in
            defer { withExtendedLifetime(access) {} }
            await writer?.value
            guard !Task.isCancelled else { return }
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
        guard !isRuntimeSuspended, !isIndexing else { return Task {} }
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
                let found = try await operation(limit)
                guard !Task.isCancelled, searchRunner.isCurrent(token) else { return }
                let results = try await Self.existingSearchResults(found)
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

    @concurrent
    private nonisolated static func existingSearchResults(_ results: [CLIPSearchResult]) async throws -> [CLIPSearchResult] {
        try results.filter { result in
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: result.url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
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

    private func trackRuntimeTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [self] in
            defer { runtimeTasks[id] = nil }
            // The operation must enter its cleanup path even if cancelled before it starts.
            await operation()
        }
        runtimeTasks[id] = task
        return task
    }

    func deactivateAndWait() async {
        isRuntimeSuspended = true
        let pending = Array(runtimeTasks.values)
        pending.forEach { $0.cancel() }
        deactivateCLIPModelRuntime()
        await searchRunner.cancelAndWait()
        for task in pending {
            await task.value
        }
    }

    private func deactivateCLIPModelRuntime() {
        clearCatalogCLIPIndexes()
        activeCLIPModelURL = nil
        modelValidationTask?.cancel()
        cancelIndexing()
        indexValidationTask?.cancel()
        searchRunner.cancel()
        clipModelStatus = .notConfigured
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = catalogURL == nil ? .noFolderSelected : .modelRequired
        isSearching = false
        clearSemanticSearchResults()
    }

    private func validateCLIPModel(at url: URL) {
        clearCatalogCLIPIndexes()
        let url = url.standardizedFileURL
        activeCLIPModelURL = url
        modelValidationTask?.cancel()
        cancelIndexing()
        indexValidationTask?.cancel()
        searchRunner.cancel()
        indexValidationID = UUID()
        clipModelStatus = .checking(url)
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = catalogURL == nil ? .noFolderSelected : .modelRequired
        isSearching = false
        clipFeatureError = nil
        clearSemanticSearchResults()

        let writer = indexingTask
        modelValidationTask = trackRuntimeTask { [self] in
            await writer?.value
            guard !Task.isCancelled, activeCLIPModelURL == url else { return }
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
        guard indexingID == operationID, indexingTask?.isCancelled == false else { return }
        indexingProgress = progress
    }

    func resetCLIPIndexSelection() {
        cancelIndexing()
        indexValidationTask?.cancel()
        searchRunner.cancel()
        indexValidationID = UUID()
        clipEngine = nil
        clipEngineDirectoryURL = nil
        clipIndexStatus = .noFolderSelected
        hasCompatibleCLIPIndex = false
        clearSemanticSearchResults()
    }
}
