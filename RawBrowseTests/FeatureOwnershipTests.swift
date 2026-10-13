import Foundation
@testable import RawBrowse
import Testing

@Suite("Extracted feature ownership")
@MainActor
struct FeatureOwnershipTests {
    @Test
    func `Settings snapshots save in call order`() async {
        let release = FeatureGate()
        let started = FeatureGate()
        var saved: [Int] = []
        let settings = SettingsModel(save: { snapshot in
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
    func `CLIP replacement rejects a non-cooperative result`() async {
        let clip = CLIPFeatureModel(settings: SettingsModel())
        let started = FeatureGate()
        let release = FeatureGate()
        let old = clip.startSearch(anchorName: nil) { _ in
            started.open()
            await release.wait()
            return [result("old")]
        }
        await started.wait()
        let latest = clip.startSearch(anchorName: "new") { _ in [result("new")] }
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
    func review(_ request: DeepAIReviewRequest,
                progress: nonisolated(nonsending) @escaping @Sendable (DeepAIReviewProgress) async -> Void) async throws -> DeepAIReviewResult {
        Issue.record("Cancelled preparation must not invoke inference")
        throw DeepAIReviewFailure.noCandidates
    }
}
