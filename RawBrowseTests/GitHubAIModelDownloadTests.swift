import CryptoKit
import Foundation
@testable import RawBrowse
import Testing

struct GitHubAIModelDownloadTests {
    @Test(arguments: ["../outside", "/absolute", "nested/../../outside", "nested//config.json", ".rawbrowse-installed.json"])
    func `manifest rejects unsafe file paths`(_ path: String) {
        let file = makeFile(path: path)
        #expect(throws: GitHubAIModelDownloadError.self) { try file.validate() }
    }

    @Test(arguments: ["https://example.com/weights", "http://github.com/rsyncOSX/AI-models/releases/download/v1/weights", "https://github.com/other/models/releases/download/v1/weights"])
    func `manifest restricts model downloads to the configured repository`(_ url: String) throws {
        #expect(try !GitHubAIModelManifest.File.isAllowedURL(#require(URL(string: url))))
    }

    @Test
    func `manifest rejects duplicate files and file directory collisions`() {
        for files in [[makeFile(), makeFile()], [makeFile(path: "weights"), makeFile(path: "weights/model")]] {
            let manifest = GitHubAIModelManifest(schemaVersion: 1, models: [.init(id: .clipDataComp, files: files)])
            #expect(throws: GitHubAIModelDownloadError.self) { try manifest.model(for: .clipDataComp) }
        }
    }

    @Test
    func `downloaded file must match both size and checksum`() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let content = Data("model data".utf8)
        try content.write(to: url)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let file = makeFile(byteCount: Int64(content.count), sha256: hash)
        try GitHubCLIPModelDownloadService.verify(url, file: file)
        let wrongSize = makeFile(byteCount: Int64(content.count + 1), sha256: hash)
        #expect(throws: GitHubAIModelDownloadError.self) {
            try GitHubCLIPModelDownloadService.verify(url, file: wrongSize)
        }
        try Data("other data".utf8).write(to: url)
        #expect(throws: GitHubAIModelDownloadError.self) {
            try GitHubCLIPModelDownloadService.verify(url, file: file)
        }
    }

    @Test
    func `unpublished service does not install a partial model`() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GitHubCLIPModelDownloadService(root: root, isEnabled: false)
        let descriptor = try #require(CLIPModelDownloadCatalog.production.descriptor(for: .clipDataComp))
        #expect(await service.state(for: descriptor) == .notConfigured)
        await #expect(throws: CLIPModelDownloadError.self) {
            try await service.download(descriptor) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test @MainActor
    func `download progress includes bytes from previous files`() async {
        let updates = AsyncStream<Double>.makeStream()
        let delegate = GitHubModelDownloadProgress(completed: 100, total: 400) {
            updates.continuation.yield($0)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.com/model")!)
        delegate.urlSession(session, downloadTask: task, didWriteData: 100,
                            totalBytesWritten: 100, totalBytesExpectedToWrite: 300)
        var iterator = updates.stream.makeAsyncIterator()
        #expect(await iterator.next() == 0.5)
        updates.continuation.finish()
    }

    @Test
    func `cancelled download does not start a network request`() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = GitHubModelDownloadProgress(completed: 0, total: 100) { _ in }
        let gate = AsyncStream<Void>.makeStream()
        let download = Task {
            for await _ in gate.stream { }
            return try await delegate.download(from: URL(string: "http://127.0.0.1:1/model")!, session: session)
        }
        download.cancel()
        gate.continuation.finish()
        do {
            _ = try await download.value
            Issue.record("A cancelled download must throw CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func makeFile(path: String = "config.json", byteCount: Int64 = 10,
                          sha256: String = String(repeating: "a", count: 64)) -> GitHubAIModelManifest.File {
        .init(path: path, url: URL(string: "https://github.com/rsyncOSX/AI-models/releases/download/v1/config.json")!,
              byteCount: byteCount, sha256: sha256)
    }
}
