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

        let loader = BrowserImageLoader()
        let files = await loader.discoverSupportedFiles(at: root)
        #expect(files.map(\.name) == names)
        let folder = await loader.folderItem(at: root)
        #expect(folder.supportedFileCount == 7)
    }
}
