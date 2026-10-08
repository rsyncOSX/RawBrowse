import Foundation
import Observation

@Observable @MainActor
final class CatalogStore {
    var catalogError: String?
    @ObservationIgnored private var catalogLoadFailed = true
    @ObservationIgnored private var persistenceGeneration = 0
    @ObservationIgnored private var isLoadingCatalogs = false
    @ObservationIgnored private let resolveCatalog: @MainActor (RememberedCatalog) throws -> (url: URL, isStale: Bool)
    @ObservationIgnored private let makeCatalog: @MainActor (URL) -> RememberedCatalog?
    @ObservationIgnored private let loadCatalogs: @MainActor () async throws -> [RememberedCatalog]

    var rootFolders: [BrowserFolderItem] = [] {
        didSet { hierarchyDidChange() }
    }

    var folderChildren: [BrowserFolderItem.ID: [BrowserFolderItem]] = [:] {
        didSet { hierarchyDidChange() }
    }

    var loadingFolderIDs: Set<BrowserFolderItem.ID> = []
    @ObservationIgnored private var securityScopedSessionURLs: Set<URL> = []
    @ObservationIgnored private var catalogSaveTask: Task<Void, Never>?
    @ObservationIgnored private var folderTasks: [BrowserFolderItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rootDiscoveryTasks: [BrowserFolderItem.ID: LatestTaskRunner] = [:]
    @ObservationIgnored private var rememberedCatalogs: [URL: RememberedCatalog] = [:]
    @ObservationIgnored private var removedCatalogURLs: Set<URL> = []

    @ObservationIgnored private var foldersByID: [BrowserFolderItem.ID: BrowserFolderItem] = [:]
    @ObservationIgnored var hierarchyChanged: (@MainActor () -> Void)?
    @ObservationIgnored var rootChildrenDiscovered: (@MainActor (BrowserFolderItem) -> Void)?
    @ObservationIgnored var folderChanged: (@MainActor (BrowserFolderItem) -> Void)?

    @ObservationIgnored private let saveCatalogs: @MainActor ([RememberedCatalog]) async throws -> Void
    @ObservationIgnored private let clearCatalogs: @MainActor () async throws -> Void
    @ObservationIgnored private let openAccess: @MainActor (URL) -> Bool
    @ObservationIgnored private let closeAccess: @MainActor (URL) -> Void
    @ObservationIgnored private let acquireLease: @MainActor (URL) -> CatalogAccessLease?
    @ObservationIgnored private let discoverFolders: @MainActor (URL) async -> [BrowserFolderItem]

    init(
        load: @escaping @MainActor () async throws -> [RememberedCatalog] = { try await RememberedCatalogStore.load() },
        save: @escaping @MainActor ([RememberedCatalog]) async throws -> Void = { try await RememberedCatalogStore.save($0) },
        clear: @escaping @MainActor () async throws -> Void = { try await RememberedCatalogStore.clear() },
        resolve: @escaping @MainActor (RememberedCatalog) throws -> (url: URL, isStale: Bool) = { try RememberedCatalogStore.resolve($0) },
        remember: @escaping @MainActor (URL) -> RememberedCatalog? = { RememberedCatalogStore.catalog(for: $0) },
        openAccess: @escaping @MainActor (URL) -> Bool = { CatalogAccess.shared.open($0) },
        closeAccess: @escaping @MainActor (URL) -> Void = { CatalogAccess.shared.close($0) },
        lease: @escaping @MainActor (URL) -> CatalogAccessLease? = { CatalogAccess.shared.lease(for: $0) },
        discoverFolders: @escaping @MainActor (URL) async -> [BrowserFolderItem] = { await BrowserImageLoader.shared.discoverFolders(at: $0) },
    ) {
        resolveCatalog = resolve
        makeCatalog = remember
        loadCatalogs = load
        saveCatalogs = save
        clearCatalogs = clear
        self.openAccess = openAccess
        self.closeAccess = closeAccess
        acquireLease = lease
        self.discoverFolders = discoverFolders
    }

    func lease(for url: URL) -> CatalogAccessLease? {
        acquireLease(url)
    }

    isolated deinit {
        for url in securityScopedSessionURLs {
            closeAccess(url)
        }
    }

    private func hierarchyDidChange() {
        foldersByID = Dictionary(rootFolders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for children in folderChildren.values {
            for folder in children {
                foldersByID[folder.id] = folder
            }
        }
        hierarchyChanged?()
    }

    func clearRememberedCatalogs() async {
        persistenceGeneration += 1
        isLoadingCatalogs = false
        for task in folderTasks.values {
            task.cancel()
        }
        for task in rootDiscoveryTasks.values {
            task.cancel()
        }
        stopActiveSecurityScopedAccess()
        rootFolders = []
        folderChildren = [:]
        loadingFolderIDs = []
        rememberedCatalogs = [:]
        removedCatalogURLs = []
        let previous = catalogSaveTask
        let clear = Task {
            await previous?.value
            do {
                try await clearCatalogs()
                catalogLoadFailed = false
            } catch {
                catalogError = "Could not clear saved folders: \(error.localizedDescription)"
            }
        }
        catalogSaveTask = clear
        await clear.value
    }

    func removeRootCatalog(_ folder: BrowserFolderItem) async {
        let url = folder.url.standardizedFileURL
        for (id, task) in folderTasks where id.standardizedFileURL.isEqualOrDescendant(of: url) {
            task.cancel()
        }
        rootDiscoveryTasks.removeValue(forKey: url)?.cancel()
        rootFolders.removeAll { $0.url.standardizedFileURL == url }
        folderChildren = folderChildren.filter { !$0.key.standardizedFileURL.isEqualOrDescendant(of: url) }
        loadingFolderIDs = loadingFolderIDs.filter { !$0.standardizedFileURL.isEqualOrDescendant(of: url) }
        rememberedCatalogs.removeValue(forKey: url)
        removedCatalogURLs.insert(url)
        closeSecurityScopedAccess(for: url)
        await saveRememberedCatalogs()
    }

    func children(of folder: BrowserFolderItem) -> [BrowserFolderItem] {
        folderChildren[folder.id] ?? []
    }

    func hasLoadedChildren(for folder: BrowserFolderItem) -> Bool {
        folderChildren[folder.id] != nil
    }

    func folder(for id: BrowserFolderItem.ID) -> BrowserFolderItem? {
        foldersByID[id]
    }

    @discardableResult
    func loadChildrenIfNeeded(for folder: BrowserFolderItem) -> Task<Void, Never>? {
        guard folderTasks[folder.id] == nil else { return folderTasks[folder.id] }
        folderTasks[folder.id] = Task {
            defer { folderTasks[folder.id] = nil }
            await loadChildren(for: [folder])
        }
        return folderTasks[folder.id]
    }

    private func loadChildren(for folders: [BrowserFolderItem]) async {
        for folder in folders where folderChildren[folder.id] == nil && !loadingFolderIDs.contains(folder.id) {
            guard startSecurityScopedAccess(for: securityScopedURL(for: folder.url)) else { continue }
            let access = lease(for: folder.url)
            defer { withExtendedLifetime(access) {} }
            loadingFolderIDs.insert(folder.id)
            let loadedFolders = await discoverFolders(folder.url)
            guard !Task.isCancelled else {
                loadingFolderIDs.remove(folder.id)
                // Cancellation abandons the entire discovery batch.
                return
            }
            setLoadedChildren(loadedFolders, for: folder)
            loadingFolderIDs.remove(folder.id)
        }
    }

    func setLoadedChildren(_ children: [BrowserFolderItem], for folder: BrowserFolderItem) {
        folderChildren[folder.id] = children
        if rootFolders.contains(where: { $0.id == folder.id }), !children.isEmpty {
            rootChildrenDiscovered?(folder)
        }
    }

    func setCLIPIndexPresence(_ isPresent: Bool, for directory: URL) {
        let folderID = directory.standardizedFileURL

        func updated(_ folder: BrowserFolderItem) -> BrowserFolderItem {
            BrowserFolderItem(
                url: folder.url,
                supportedFileCount: folder.supportedFileCount,
                hasCLIPIndex: isPresent,
            )
        }

        if let index = rootFolders.firstIndex(where: { $0.url.standardizedFileURL == folderID }) {
            rootFolders[index] = updated(rootFolders[index])
        }

        for parentID in Array(folderChildren.keys) {
            guard var children = folderChildren[parentID],
                  let index = children.firstIndex(where: { $0.url.standardizedFileURL == folderID })
            else { continue }
            children[index] = updated(children[index])
            folderChildren[parentID] = children
        }

        if let folder = foldersByID[folderID] {
            folderChanged?(folder)
        }
    }

    func stopActiveSecurityScopedAccess() {
        for url in securityScopedSessionURLs {
            closeAccess(url)
        }
        securityScopedSessionURLs.removeAll()
    }

    private func closeSecurityScopedAccess(for url: URL) {
        closeAccess(url)
        securityScopedSessionURLs.remove(url.standardizedFileURL)
    }

    func securityScopedURL(for folderURL: URL) -> URL {
        let standardizedFolderURL = folderURL.standardizedFileURL
        return rootFolders
            .map(\.url)
            .filter { rootURL in
                standardizedFolderURL.isEqualOrDescendant(of: rootURL.standardizedFileURL)
            }
            .max { first, second in
                first.standardizedFileURL.pathComponents.count < second.standardizedFileURL.pathComponents.count
            } ?? folderURL
    }

    private func rememberCatalog(at url: URL) {
        guard let catalog = makeCatalog(url) else {
            catalogError = "Could not remember access to \(url.lastPathComponent). Please add the folder again."
            return
        }
        removedCatalogURLs.remove(url.standardizedFileURL)
        rememberedCatalogs[url.standardizedFileURL] = catalog
        enqueueCatalogSave()
    }

    @discardableResult
    private func enqueueCatalogSave() -> Task<Void, Never> {
        let generation = persistenceGeneration
        let catalogs = rememberedCatalogs.values.sorted { $0.path < $1.path }
        let previousSave = catalogSaveTask
        let task = Task {
            await previousSave?.value
            guard generation == persistenceGeneration, !isLoadingCatalogs else { return }
            guard !catalogLoadFailed else {
                catalogError = "Saved folders could not be loaded. Changes will not be saved until loading succeeds. The existing file has been preserved."
                return
            }
            do {
                try await saveCatalogs(catalogs)
            } catch {
                catalogError = "Could not save folders: \(error.localizedDescription)"
            }
        }
        catalogSaveTask = task
        return task
    }

    func saveRememberedCatalogs() async {
        await enqueueCatalogSave().value
    }

    private func uniqueFolders(_ folders: [BrowserFolderItem]) -> [BrowserFolderItem] {
        var seen: Set<URL> = []
        return folders
            .filter { folder in
                guard !seen.contains(folder.url) else { return false }
                seen.insert(folder.url)
                return true
            }
    }

    func startSecurityScopedAccess(for url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard openAccess(url) else { return false }
        securityScopedSessionURLs.insert(url)
        return true
    }

    func loadRememberedCatalogs() async {
        guard !isLoadingCatalogs else { return }
        isLoadingCatalogs = true
        persistenceGeneration += 1
        let generation = persistenceGeneration
        catalogError = nil
        defer {
            if generation == persistenceGeneration { isLoadingCatalogs = false }
        }
        let sessionAtStart = rememberedCatalogs
        await catalogSaveTask?.value
        guard generation == persistenceGeneration else { return }
        let catalogs: [RememberedCatalog]
        do {
            catalogs = try await loadCatalogs()
            guard generation == persistenceGeneration else { return }
            catalogLoadFailed = false
        } catch {
            guard generation == persistenceGeneration else { return }
            catalogLoadFailed = true
            catalogError = "Could not load saved folders: \(error.localizedDescription). The existing file has been preserved; changes will not be saved until loading succeeds."
            return
        }
        var unavailablePaths: [String] = []
        var renewedBookmarks = false
        var loadedCatalogs: [URL: RememberedCatalog] = [:]
        var loadedFolders: [BrowserFolderItem] = []

        for catalog in catalogs {
            guard !removedCatalogURLs.contains(URL(filePath: catalog.path).standardizedFileURL) else { continue }
            // Retain unavailable entries so a later save cannot erase them.
            loadedCatalogs[URL(filePath: catalog.path).standardizedFileURL] = catalog
            let resolution: (url: URL, isStale: Bool)
            do { resolution = try resolveCatalog(catalog) }
            catch {
                unavailablePaths.append(catalog.path)
                continue
            }
            let standardizedURL = resolution.url.standardizedFileURL
            guard startSecurityScopedAccess(for: standardizedURL) else {
                unavailablePaths.append(catalog.path)
                continue
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                closeSecurityScopedAccess(for: standardizedURL)
                unavailablePaths.append(catalog.path)
                continue
            }

            loadedCatalogs.removeValue(forKey: URL(filePath: catalog.path).standardizedFileURL)
            loadedCatalogs[standardizedURL] = catalog
            if resolution.isStale || catalog.path != standardizedURL.path {
                if let renewed = makeCatalog(standardizedURL) {
                    loadedCatalogs[standardizedURL] = renewed
                    renewedBookmarks = true
                } else {
                    unavailablePaths.append(catalog.path)
                }
            }
            let loadedFolder = await BrowserImageLoader.shared.folderItem(at: standardizedURL)
            guard generation == persistenceGeneration else { return }
            guard !removedCatalogURLs.contains(standardizedURL) else {
                loadedCatalogs.removeValue(forKey: standardizedURL)
                continue
            }
            loadedFolders.append(loadedFolder)
        }

        // A folder may have been added while the file was being read.
        let hadSessionCatalogs = !rememberedCatalogs.isEmpty
        for (url, sessionCatalog) in rememberedCatalogs {
            if loadedCatalogs[url] == nil || sessionAtStart[url] != sessionCatalog {
                loadedCatalogs[url] = sessionCatalog
            }
        }
        loadedCatalogs = loadedCatalogs.filter { !removedCatalogURLs.contains($0.key) }
        loadedFolders.removeAll { removedCatalogURLs.contains($0.url.standardizedFileURL) }
        rememberedCatalogs = loadedCatalogs
        rootFolders = uniqueFolders(loadedFolders + rootFolders)
        isLoadingCatalogs = false
        if !unavailablePaths.isEmpty {
            catalogError = "Some saved folders could not be restored. Their entries have been kept. Reconnect the drive or add the folders again:\n" + unavailablePaths.joined(separator: "\n")
        }
        if renewedBookmarks || hadSessionCatalogs || !removedCatalogURLs.isEmpty { await saveRememberedCatalogs() }
        await loadChildren(for: rootFolders)
    }

    func addRootFolder(_ url: URL) -> BrowserFolderItem? {
        let standardizedURL = url.standardizedFileURL
        guard startSecurityScopedAccess(for: standardizedURL) else { return nil }
        let folder = BrowserFolderItem(url: standardizedURL)
        if !rootFolders.contains(where: { $0.url == standardizedURL }) {
            rootFolders.append(folder)
            let access = lease(for: standardizedURL)
            let runner = rootDiscoveryTasks[folder.id] ?? LatestTaskRunner()
            rootDiscoveryTasks[folder.id] = runner
            runner.start { [self] token in
                defer { withExtendedLifetime(access) {} }
                let discoveredFolder = await BrowserImageLoader.shared.folderItem(at: standardizedURL)
                guard !Task.isCancelled, runner.isCurrent(token),
                      let rootIndex = rootFolders.firstIndex(where: { $0.id == discoveredFolder.id })
                else {
                    return
                }
                rootFolders[rootIndex] = discoveredFolder
                folderChanged?(discoveredFolder)
                await loadChildren(for: [discoveredFolder])
            }
        }
        rememberCatalog(at: standardizedURL)
        return folder
    }
}
