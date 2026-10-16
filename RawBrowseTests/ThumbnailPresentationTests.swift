import AppKit
@testable import RawBrowse
import Testing

@MainActor
@Suite("Thumbnail publication")
struct ThumbnailPresentationTests {
    @Test
    func supersededSizeCannotOverwriteNewResult() async {
        let model = ThumbnailPresentationModel()
        let old = NSImage(size: NSSize(width: 10, height: 10))
        let latest = NSImage(size: NSSize(width: 20, height: 20))
        let gate = ThumbnailGate()
        let url = URL(filePath: "/tmp/thumbnail-publication.jpg")
        let task = Task { await model.load(request: ThumbnailRequest(url: url, targetSize: 100)) {
            await gate.wait()
            return old
        } }
        await gate.waitUntilStarted()
        await model.load(request: ThumbnailRequest(url: url, targetSize: 200)) { latest }
        gate.release()
        await task.value
        #expect(model.image === latest)
        #expect(!model.isLoading)
    }

    @Test
    func cancellationAndDisappearanceRejectNoncooperativeResults() async {
        let model = ThumbnailPresentationModel()
        let gate = ThumbnailGate()
        let task = Task { await model.load(request: ThumbnailRequest(url: URL(filePath: "/tmp/cancel.jpg"), targetSize: 100)) {
            await gate.wait()
            return NSImage(size: NSSize(width: 10, height: 10))
        } }
        await gate.waitUntilStarted()
        task.cancel()
        model.invalidate()
        gate.release()
        await task.value
        #expect(model.image == nil)
        #expect(!model.isLoading)
    }

    @Test
    func sourceReplacementChangesIdentityAndRejectsOldPixels() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "photo.jpg")
        try Data([1]).write(to: url)
        let request = ThumbnailRequest(url: url, targetSize: 100)
        let model = ThumbnailPresentationModel()
        let gate = ThumbnailGate()
        let task = Task { await model.load(request: request) {
            await gate.wait()
            return NSImage(size: NSSize(width: 10, height: 10))
        } }
        await gate.waitUntilStarted()
        try Data([1, 2]).write(to: url)
        #expect(request != ThumbnailRequest(url: url, targetSize: 100))
        gate.release()
        await task.value
        #expect(model.image == nil)
    }

    @Test
    func changingSourceClearsPreviousImageWhileLoading() async {
        let model = ThumbnailPresentationModel()
        await model.load(request: ThumbnailRequest(url: URL(filePath: "/tmp/first.jpg"), targetSize: 100)) {
            NSImage(size: NSSize(width: 10, height: 10))
        }
        #expect(model.image != nil)
        let gate = ThumbnailGate()
        let task = Task { await model.load(request: ThumbnailRequest(url: URL(filePath: "/tmp/second.jpg"), targetSize: 100)) {
            await gate.wait()
            return nil
        } }
        await gate.waitUntilStarted()
        #expect(model.image == nil)
        #expect(model.isLoading)
        gate.release()
        await task.value
    }
}

@MainActor
private final class ThumbnailGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
