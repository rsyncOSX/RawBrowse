import Foundation
@testable import RawBrowse
import Testing

@MainActor
struct BrowserFileDiscoveryTests {
    @Test
    func `mixed folder includes RAW files and rendered images in discovery and count`() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let names = (1 ... 6).map { "DSC\($0).ARW" } + ["edited.jpeg"]
        for name in names + ["notes.txt", ".hidden.ARW"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("directory.ARW"),
            withIntermediateDirectories: true,
        )

        let loader = BrowserImageLoader(fullSizeCache: FullSizeJPGDiskCache(
            cacheDirectory: root.appendingPathComponent("preview-cache", isDirectory: true),
        ))
        let files = try await loader.discoverSupportedFiles(at: root)
        #expect(files.map(\.name) == names)
        let folder = await loader.folderItem(at: root)
        #expect(folder.supportedFileCount == 7)
        #expect(!folder.hasRAW9Files)
    }

    @Test
    func `initial folder discovery skips RAW 9 decoder probes`() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appending(path: "photo.ARW"))
        let folder = BrowserImageLoader.folderItem(at: root)
        #expect(folder.supportedFileCount == 1)
        #expect(!folder.hasRAW9Files)
    }

    @Test
    func `compatibility scan publishes after initial hierarchy and preserves folder metadata`() async throws {
        let folder = BrowserFolderItem(url: URL(filePath: "/test/RAW9"), supportedFileCount: 7, hasCLIPIndex: true)
        var finish: CheckedContinuation<Bool, Never>?
        let catalog = CatalogStore(lease: { _ in nil }, checkRAW9: { _ in
            await withCheckedContinuation { finish = $0 }
        })
        catalog.rootFolders = [folder]
        #expect(!catalog.isScanningRAW9Compatibility)
        #expect(catalog.rootFolders == [folder])
        for _ in 0 ..< 100 where finish == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(catalog.isScanningRAW9Compatibility)
        let continuation = try #require(finish)
        continuation.resume(returning: true)
        for _ in 0 ..< 100 where catalog.isScanningRAW9Compatibility {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!catalog.isScanningRAW9Compatibility)
        #expect(catalog.rootFolders.first?.hasRAW9Files == true)
        #expect(catalog.rootFolders.first?.supportedFileCount == 7)
        #expect(catalog.rootFolders.first?.hasCLIPIndex == true)
    }

    @Test
    func `removed folder ignores an in flight compatibility result`() async throws {
        let folder = BrowserFolderItem(url: URL(filePath: "/test/removed"))
        var finish: CheckedContinuation<Bool, Never>?
        var published = false
        let catalog = CatalogStore(lease: { _ in nil }, checkRAW9: { _ in
            await withCheckedContinuation { finish = $0 }
        })
        catalog.folderChanged = { _ in published = true }
        catalog.rootFolders = [folder]
        for _ in 0 ..< 100 where finish == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(finish)
        catalog.rootFolders = []
        continuation.resume(returning: true)
        for _ in 0 ..< 100 where catalog.isScanningRAW9Compatibility {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!published)
        #expect(catalog.rootFolders.isEmpty)
        #expect(!catalog.isScanningRAW9Compatibility)
    }

    @Test
    func `RAW 9 discovery skips non RAW files and stops probing after a match`() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first.ARW", "second.ARW", "edited.jpeg", "notes.txt", ".hidden.ARW"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appending(path: "directory.ARW"), withIntermediateDirectories: true)
        var probes: [URL] = []
        let folder = BrowserImageLoader.folderItem(at: root) { url in
            probes.append(url)
            return true
        }
        #expect(folder.hasRAW9Files)
        #expect(folder.supportedFileCount == 3)
        #expect(probes.count == 1)
        #expect(probes.first?.pathExtension == "ARW")

        probes = []
        let unsupported = BrowserImageLoader.folderItem(at: root) { url in
            probes.append(url)
            return false
        }
        #expect(!unsupported.hasRAW9Files)
        #expect(probes.count == 2)
    }

    @Test
    func `Missing directory is a scan error rather than an empty folder`() async {
        let folder = BrowserFolderItem(url: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let contents = BrowserContentsModel()
        await contents.scan(folder, access: nil).value
        #expect(contents.scanError != nil)
        #expect(contents.files.isEmpty)
        #expect(!contents.isScanning)
        contents.clear()
        #expect(contents.scanError == nil)
    }

    @Test
    func `Successfully scanned empty folder has no error`() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = BrowserContentsModel()
        await contents.scan(BrowserFolderItem(url: root), access: nil).value
        #expect(contents.scanError == nil)
        #expect(contents.files.isEmpty)
    }
}
