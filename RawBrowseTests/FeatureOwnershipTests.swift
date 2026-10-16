import Foundation
@testable import RawBrowse
import Testing

@Suite("Extracted feature ownership")
@MainActor
struct FeatureOwnershipTests {
    @Test
    func `Failed sidecar snapshots survive navigation and retry without replacing newer edits`() async throws {
        let first = URL(filePath: "/tmp/failed-first.ARW")
        let second = URL(filePath: "/tmp/failed-second.ARW")
        let probe = SidecarRetryProbe()
        let session = RAW9EditingSession(load: { _ in RAW9Adjustments() }, save: { adjustments, url in
            if probe.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            probe.saved[url] = adjustments
        })
        _ = session.prepare(for: first)
        session.raw9Adjustments = RAW9Adjustments(exposure: 1)
        // Navigate before the debounced write fails.
        session.close()
        _ = session.prepare(for: second)
        session.raw9Adjustments = RAW9Adjustments(exposure: 2)
        await session.finishSaving()
        #expect(session.failedSaves.count == 2)
        #expect(session.hasUnsavedChanges)
        _ = session.prepare(for: first)
        try await session.restore(for: first, initialAdjustments: RAW9Adjustments())
        #expect(session.raw9Adjustments.exposure == 1)
        probe.shouldFail = false
        let retry = try #require(session.retrySave(for: first))
        // A newer edit must supersede the retry snapshot.
        session.raw9Adjustments = RAW9Adjustments(exposure: 3)
        await retry.value
        await session.finishSaving()
        #expect(probe.saved[first]?.exposure == 3)
        #expect(session.failedSaves[first] == nil)
        #expect(session.failedSaves[second] != nil)
        await session.retrySave(for: second)?.value
        #expect(probe.saved[second]?.exposure == 2)
        #expect(session.failedSaves.isEmpty)
        #expect(!session.hasUnsavedChanges)
        #expect(session.raw9Adjustments.exposure == 3)
    }

    @Test
    func `Search omits missing files and directories while preserving rank order`() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "present.jpg")
        try Data().write(to: file)
        let clip = CLIPFeatureModel(settings: SettingsModel(initialValues: BrowserSettings(), save: { _ in }))
        await clip.startSearch(anchorName: nil) { _ in
            [CLIPSearchResult(rank: 1, score: 1, fileName: "missing", path: root.appending(path: "missing.jpg").path),
             CLIPSearchResult(rank: 2, score: 0.8, fileName: "present", path: file.path),
             CLIPSearchResult(rank: 3, score: 0.5, fileName: "directory", path: root.path)]
        }.value
        #expect(clip.semanticSearchResults.map(\.url) == [file])
        #expect(clip.semanticSearchResults.first?.rank == 2)
        #expect(clip.semanticFiles.map(\.url) == [file])
    }

    @Test
    func `Folder refresh reconciles deleted added and selected files`() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "kept.jpg")
        let added = root.appending(path: "added.jpg")
        try Data().write(to: kept)
        try Data().write(to: added)
        let removed = BrowserFileItem(url: root.appending(path: "removed.jpg"))
        let survivor = BrowserFileItem(url: kept)
        let contents = BrowserContentsModel()
        contents.selectedFolder = BrowserFolderItem(url: root)
        contents.files = [removed, survivor]
        let catalog = CatalogStore(openAccess: { _ in true }, closeAccess: { _ in }, lease: { _ in nil })
        let model = FileBrowserViewModel(settings: SettingsModel(initialValues: BrowserSettings(), save: { _ in }),
                                         catalog: catalog, contents: contents)
        model.selection.selectedFileIDs = [removed.id, survivor.id]
        model.selection.selectedFileID = removed.id
        let refresh = try #require(model.refreshSelectedFolder())
        #expect(contents.files.isEmpty)
        await refresh.value
        #expect(Set(contents.files.map(\.url)) == [kept, added])
        #expect(model.selection.selectedFiles.map(\.url) == [kept])
        #expect(model.selection.selectedFile?.url == kept)
        #expect(contents.scanError == nil)
    }

    @Test
    func `Settings snapshots save in call order`() async {
        let release = FeatureGate()
        let started = FeatureGate()
        var saved: [Int] = []
        let settings = SettingsModel(initialValues: BrowserSettings(), save: { snapshot in
            if snapshot.semanticSearchLimit == 10 {
                started.open()
                await release.wait()
            }
            saved.append(snapshot.semanticSearchLimit)
        })
        settings.values.semanticSearchLimit = 10
        settings.persistSettings()
        await started.wait()
        settings.values.semanticSearchLimit = 20
        let second = settings.persistSettings()
        release.open()
        await second.value
        #expect(saved == [10, 20])
    }

    @Test
    func `Failed settings load never persists defaults`() async {
        var writes = 0
        let model = SettingsModel(load: { throw CocoaError(.fileReadNoPermission) }, save: { _ in writes += 1 })
        await model.loadSettings()
        await model.persistSettings().value
        #expect(writes == 0)
        #expect(model.settingsError != nil)
    }

    @Test
    func `Malformed settings remain untouched after load`() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "settings.json")
        let original = Data("{invalid settings".utf8)
        try original.write(to: url)
        let model = SettingsModel(load: { try await BrowserSettingsStore.load(from: url) },
                                  save: { try await BrowserSettingsStore.save($0, to: url) })
        await model.loadSettings()
        await model.persistSettings().value
        #expect(try Data(contentsOf: url) == original)
        #expect(model.settingsError != nil)
    }

    @Test
    func `Failed settings save reports unsaved preferences and can retry`() async {
        var shouldFail = true
        let model = SettingsModel(initialValues: BrowserSettings(), save: { _ in
            if shouldFail {
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        await model.persistSettings().value
        #expect(model.settingsError != nil)
        #expect(model.hasUnsavedChanges)
        shouldFail = false
        await model.retryPersistence()
        #expect(model.settingsError == nil)
        #expect(!model.hasUnsavedChanges)
    }

    @Test
    func `CLIP replacement rejects a non-cooperative result`() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "new.jpg")
        try Data().write(to: url)
        let clip = CLIPFeatureModel(settings: SettingsModel())
        let started = FeatureGate()
        let release = FeatureGate()
        let old = clip.startSearch(anchorName: nil) { _ in
            started.open()
            await release.wait()
            return [result("old")]
        }
        await started.wait()
        let latest = clip.startSearch(anchorName: "new") { _ in [CLIPSearchResult(rank: 1, score: 1, fileName: "new", path: url.path)] }
        await latest.value
        release.open()
        await old.value
        #expect(clip.semanticSearchResults.map(\.fileName) == ["new"])
        #expect(clip.similaritySearchAnchorName == "new")
        #expect(!clip.isSearching)
    }

    @Test
    func `Runtime shutdown awaits an already replaced non-cooperative search`() async {
        let clip = CLIPFeatureModel(settings: SettingsModel())
        let started = FeatureGate()
        let release = FeatureGate()
        let old = clip.startSearch(anchorName: nil) { _ in
            started.open()
            await release.wait()
            return []
        }
        await started.wait()
        await clip.startSearch(anchorName: nil) { _ in [] }.value
        var drained = false
        let shutdown = Task {
            await clip.deactivateAndWait()
            drained = true
        }
        await Task.yield()
        #expect(!drained)
        release.open()
        await old.value
        await shutdown.value
        #expect(drained)
    }

    @Test(arguments: ["cancel", "reset", "deactivate", "replace"])
    func `Index transitions retain a cancelled writer until it exits`(transition: String) async throws {
        let clip = CLIPFeatureModel(settings: SettingsModel())
        let started = FeatureGate()
        let release = FeatureGate()
        let directory = URL(filePath: "/tmp/index-ownership")
        let writer = try #require(clip.beginIndexing(directory: directory) {
            started.open()
            await release.wait()
            return CLIPIndexSummary(discovered: 1, indexed: 1, failures: [])
        })
        await started.wait()
        switch transition {
        case "reset": clip.resetCLIPIndexSelection()
        case "deactivate": clip.activateModel(at: nil)
        case "replace": clip.activateModel(at: URL(filePath: "/tmp/missing-model"))
        default: clip.cancelIndexing()
        }
        #expect(writer.isCancelled)
        #expect(clip.isIndexing)
        #expect(clip.indexingDirectoryURL == directory)
        #expect(clip.beginIndexing(directory: directory) {
            Issue.record("A replacement writer must not start before cancellation drains")
            return CLIPIndexSummary(discovered: 0, indexed: 0, failures: [])
        } == nil)
        release.open()
        await writer.value
        #expect(!clip.isIndexing)
        #expect(clip.indexingDirectoryURL == nil)
        #expect(clip.lastIndexSummary == nil)
        await clip.deactivateAndWait()
    }

    @Test
    func `Download shutdown cancels and drains workers and rejects new work`() async throws {
        let downloads = ModelDownloadsModel()
        let started = FeatureGate()
        let release = FeatureGate()
        let worker = try #require(downloads.beginDownload(.clipDataComp) {
            started.open()
            await release.wait()
        })
        await started.wait()
        var finished = false
        let shutdown = Task {
            await downloads.cancelAndWait()
            finished = true
        }
        // Wait for cancellation admission, rather than relying on scheduler timing.
        while !worker.isCancelled { await Task.yield() }
        #expect(!finished)
        #expect(downloads.beginDownload(.sam3) { Issue.record("Shutdown must reject downloads") } == nil)
        release.open()
        await shutdown.value
        #expect(finished)
    }

    @Test
    func `Termination waits for a cancelled download to clean up`() async throws {
        let model = FileBrowserViewModel()
        let started = FeatureGate()
        let release = FeatureGate()
        var cleanedUp = false
        let worker = try #require(model.downloads.beginDownload(.clipDataComp) {
            started.open()
            await release.wait()
            cleanedUp = true
        })
        await started.wait()
        let exports = RAW9ExportQueue(operation: { _ in }, startAccess: { _ in false }, stopAccess: { _ in })
        var finished = false
        let quit = Task {
            #expect(await model.prepareForTermination(exports: exports) == nil)
            finished = true
        }
        while !worker.isCancelled { await Task.yield() }
        #expect(!finished)
        #expect(!cleanedUp)
        release.open()
        await quit.value
        #expect(cleanedUp)
        #expect(finished)
    }

    @Test
    func `Termination drains non-cooperative indexing and prevents restart`() async throws {
        let model = FileBrowserViewModel()
        let started = FeatureGate()
        let release = FeatureGate()
        let directory = URL(filePath: "/tmp/quit-index")
        let writer = try #require(model.clip.beginIndexing(directory: directory) {
            started.open()
            await release.wait()
            return CLIPIndexSummary(discovered: 1, indexed: 1, failures: [])
        })
        await started.wait()
        let exports = RAW9ExportQueue(operation: { _ in }, startAccess: { _ in false }, stopAccess: { _ in })
        var finished = false
        let quit = Task {
            #expect(await model.prepareForTermination(exports: exports) == nil)
            finished = true
        }
        while !writer.isCancelled { await Task.yield() }
        #expect(!finished)
        #expect(model.clip.isIndexing)
        release.open()
        await quit.value
        #expect(!model.clip.isIndexing)
        #expect(model.clip.beginIndexing(directory: directory) {
            Issue.record("Termination must reject indexing")
            return CLIPIndexSummary(discovered: 0, indexed: 0, failures: [])
        } == nil)
    }

    @Test
    func `CLIP clearing invalidates a suspended search`() async {
        let clip = CLIPFeatureModel(settings: SettingsModel())
        let started = FeatureGate()
        let release = FeatureGate()
        let pending = clip.startSearch(anchorName: nil) { _ in
            started.open()
            await release.wait()
            return [result("late")]
        }
        await started.wait()
        clip.clearSemanticSearchResults()
        release.open()
        await pending.value
        #expect(clip.semanticSearchResults.isEmpty)
        #expect(!clip.semanticSearchActive)
        #expect(!clip.isSearching)
    }

    @Test
    func `Deep Review owns preparation and drains cancellation before another run`() async {
        let started = FeatureGate()
        let release = FeatureGate()
        let feature = DeepAIReviewFeature(availability: .available(location: nil), service: NeverReviewService())
        let signature = BurstGroupSignature(memberKeys: ["photo"])
        let original = Task {
            await feature.startPreparing(groupID: 1, totalCount: 1) {
                started.open()
                await release.wait() // Deliberately ignores cancellation.
                return DeepAIReviewRequest(groupID: 1, groupSignature: signature, candidates: [],
                                           preset: .auto, scope: .full, scoringSource: .embeddedPreview)
            }
        }
        await started.wait()
        #expect(feature.isRunning)
        #expect(feature.state == .preparing(groupID: 1, totalCount: 1))
        feature.cancel()
        var replacementPrepared = false
        await feature.startPreparing(groupID: 2, totalCount: 1) {
            replacementPrepared = true
            throw DeepAIReviewFailure.noCandidates
        }
        #expect(!replacementPrepared)
        release.open()
        await original.value
        #expect(!feature.isRunning)
        #expect(feature.state == .cancelled(groupID: 1))
        #expect(feature.result(for: signature) == nil)
    }

    @Test
    func `User edits back to defaults supersede a pending sidecar read`() async throws {
        let started = FeatureGate()
        let release = FeatureGate()
        let session = RAW9EditingSession(load: { _ in
            started.open()
            await release.wait()
            return RAW9Adjustments(exposure: 2)
        }, save: { _, _ in })
        let url = URL(filePath: "/tmp/sidecar-photo.nef")
        _ = session.prepare(for: url)
        let initial = session.raw9Adjustments
        let restore = Task { try await session.restore(for: url, initialAdjustments: initial) }
        await started.wait()
        session.raw9Adjustments.exposure = 1
        session.raw9Adjustments.exposure = 0
        release.open()
        try await restore.value
        #expect(session.raw9Adjustments.exposure == 0)
        await session.finishSaving()
    }

    @Test
    func `Termination waits for final edits and queued exports`() async {
        let started = FeatureGate()
        let release = FeatureGate()
        var saved = false
        let raw9 = RAW9EditingSession(save: { _, _ in saved = true })
        _ = raw9.prepare(for: URL(filePath: "/tmp/quit.nef"))
        raw9.raw9Adjustments.exposure = 1
        let exports = RAW9ExportQueue(operation: { _ in
            await started.open()
            await release.wait()
        }, startAccess: { _ in false }, stopAccess: { _ in })
        exports.enqueue(RAW9ExportJob(source: URL(filePath: "/tmp/quit.nef"), adjustments: RAW9Adjustments(),
                                      destination: URL(filePath: "/tmp/quit.jpg"), type: "public.jpeg"))
        await started.wait()
        let model = FileBrowserViewModel(raw9: raw9)
        var finished = false
        let quit = Task {
            let failure = await model.prepareForTermination(exports: exports)
            #expect(failure == nil)
            finished = true
        }
        await raw9.finishSaving()
        #expect(saved)
        #expect(!finished)
        release.open()
        await quit.value
        #expect(exports.outstandingCount == 0)
        #expect(!raw9.hasUnsavedChanges)
    }

    @Test
    func `Termination is cancelled when final edits fail to save`() async {
        let raw9 = RAW9EditingSession(save: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        _ = raw9.prepare(for: URL(filePath: "/tmp/quit-failure.nef"))
        raw9.raw9Adjustments.exposure = 1
        let model = FileBrowserViewModel(raw9: raw9)
        let exports = RAW9ExportQueue(operation: { _ in }, startAccess: { _ in false }, stopAccess: { _ in })
        #expect(await model.prepareForTermination(exports: exports) != nil)
        #expect(raw9.hasUnsavedChanges)
        #expect(!model.isShuttingDown)
    }

    @Test
    func `Sidecar writes finish in order after changing files and closing`() async {
        var saved: [(URL, Double)] = []
        let session = RAW9EditingSession(save: { adjustments, url in
            saved.append((url, adjustments.exposure))
        })
        let first = URL(filePath: "/tmp/first.nef")
        let second = URL(filePath: "/tmp/second.nef")
        _ = session.prepare(for: first)
        session.raw9Adjustments.exposure = 1
        _ = session.prepare(for: second)
        session.raw9Adjustments.exposure = 2
        session.close()
        await session.finishSaving()
        #expect(saved.map { $0.0 } == [first, second])
        #expect(saved.map { $0.1 } == [1, 2])
    }

    @Test
    func `Starting a scan removes previous images from display and selection`() async {
        let release = FeatureGate()
        let started = FeatureGate()
        let contents = BrowserContentsModel(discover: { _ in
            started.open()
            await release.wait()
            return ([], [])
        })
        let model = FileBrowserViewModel(contents: contents)
        let old = BrowserFileItem(url: URL(filePath: "/tmp/old/photo.jpg"))
        contents.files = [old]
        model.selection.selectOnlyFile(old)
        let scan = contents.scan(BrowserFolderItem(url: URL(filePath: "/tmp/new")), access: nil)
        await started.wait()
        #expect(contents.isScanning)
        #expect(contents.files.isEmpty)
        #expect(model.selection.displayedFiles.isEmpty)
        #expect(model.selection.selectedFile == nil)
        model.openZoom()
        #expect(!model.zoom.presentation.zoomOverlayVisible)
        release.open()
        await scan.value
    }

    @Test
    func `Scan replacement rejects stale discovery and clears progress`() async {
        let started = FeatureGate()
        let release = FeatureGate()
        let first = BrowserFolderItem(url: URL(filePath: "/tmp/first"))
        let second = BrowserFolderItem(url: URL(filePath: "/tmp/second"))
        let contents = BrowserContentsModel(discover: { url in
            if url == first.url {
                started.open(); await release.wait()
            }
            return ([], [BrowserFileItem(url: url.appendingPathComponent("photo.jpg"))])
        })
        let old = contents.scan(first, access: nil)
        await started.wait()
        let latest = contents.scan(second, access: nil)
        await latest.value
        release.open()
        await old.value
        #expect(contents.selectedFolder?.id == second.id)
        #expect(contents.files.first?.url == second.url.appendingPathComponent("photo.jpg"))
        #expect(!contents.isScanning)
    }

    @Test
    func `Removing a selected catalog prevents suspended scan publication`() async {
        let started = FeatureGate()
        let release = FeatureGate()
        let root = BrowserFolderItem(url: URL(filePath: "/tmp/catalog"))
        let contents = BrowserContentsModel(discover: { url in
            started.open()
            await release.wait()
            return ([], [BrowserFileItem(url: url.appendingPathComponent("late.jpg"))])
        })
        let catalog = CatalogStore(save: { _ in }, clear: {}, openAccess: { _ in true },
                                   closeAccess: { _ in }, lease: { _ in nil })
        catalog.rootFolders = [root]
        let model = FileBrowserViewModel(catalog: catalog, contents: contents)
        let pending = contents.scan(root, access: nil)
        await started.wait()
        await model.removeRootCatalog(root)
        release.open()
        await pending.value
        #expect(contents.files.isEmpty)
        #expect(contents.selectedFolder == nil)
        #expect(!contents.isScanning)
        #expect(model.selection.selectedFileIDs.isEmpty)
        #expect(model.sidebar.visibleSidebarFolders.isEmpty)
    }

    @Test
    func `Sidebar projection updates after asynchronous discovery and removal`() async {
        let root = BrowserFolderItem(url: URL(filePath: "/tmp/catalog"))
        let child = BrowserFolderItem(url: root.url.appendingPathComponent("child"))
        let started = FeatureGate()
        let release = FeatureGate()
        let catalog = CatalogStore(save: { _ in }, clear: {}, openAccess: { _ in true },
                                   closeAccess: { _ in }, lease: { _ in nil }, discoverFolders: { _ in
                                       started.open()
                                       await release.wait()
                                       return [child]
                                   })
        let model = FileBrowserViewModel(catalog: catalog)
        catalog.rootFolders = [root]
        let discovery = catalog.loadChildrenIfNeeded(for: root)
        await started.wait()
        #expect(model.sidebar.visibleSidebarFolders.map(\.id) == [root.id])
        release.open()
        await discovery?.value
        #expect(model.sidebar.visibleSidebarFolders.map(\.id) == [root.id, child.id])
        #expect(catalog.folder(for: child.id) == child)
        #expect(model.sidebar.depthByID[child.id] == 1)
        #expect(model.sidebar.destination(by: 1, selectedFolder: root, enabled: true)?.id == child.id)
        #expect(model.sidebar.destination(by: 1, selectedFolder: child, enabled: true) == nil)
        #expect(model.sidebar.destination(by: 1, selectedFolder: root, enabled: false) == nil)
        await model.removeRootCatalog(root)
        #expect(model.sidebar.visibleSidebarFolders.isEmpty)
        #expect(model.sidebar.expandedFolderIDs.isEmpty)
        #expect(catalog.folder(for: child.id) == nil)
    }

    @Test
    func `Live editing session saves and restores through its sidecar actor`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.nef")
        let writer = RAW9EditingSession()
        _ = writer.prepare(for: url)
        writer.raw9Adjustments.exposure = 1
        await writer.finishSaving()
        #expect(FileManager.default.fileExists(atPath: RAW9SidecarStore.sidecarURL(for: url).path))
        let reader = RAW9EditingSession()
        _ = reader.prepare(for: url)
        try await reader.restore(for: url, initialAdjustments: reader.raw9Adjustments)
        #expect(reader.raw9Adjustments.exposure == 1)
    }

    private func result(_ name: String) -> CLIPSearchResult {
        CLIPSearchResult(rank: 1, score: 1, fileName: name, path: "/tmp/\(name).jpg")
    }
}

@MainActor
private final class FeatureGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private nonisolated struct NeverReviewService: DeepAIReviewServicing {
    func review(_: DeepAIReviewRequest,
                progress _: nonisolated(nonsending) @escaping @Sendable (DeepAIReviewProgress) async -> Void) async throws -> DeepAIReviewResult {
        Issue.record("Cancelled preparation must not invoke inference")
        throw DeepAIReviewFailure.noCandidates
    }
}

@MainActor
private final class SidecarRetryProbe {
    var shouldFail = true
    var saved: [URL: RAW9Adjustments] = [:]
}
