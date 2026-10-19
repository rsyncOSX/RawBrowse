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
