import CoreGraphics
import Foundation
@testable import RawBrowse
import Testing

@Suite("Close-ups contracts and lifecycle")
struct CloseUpTests {
    @Test(arguments: [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: -2, y: 4)])
    func regionsStayInsideImage(center: CGPoint) {
        let region = CloseUpRegion(center: center, fraction: 0.25)
        let bounds = region.pixelBounds(width: 600, height: 400)
        #expect(CGRect(x: 0, y: 0, width: 600, height: 400).contains(bounds))
        #expect(bounds.width == 150)
        #expect(bounds.height == 100)
    }

    @Test func invalidRegionValuesAreSafe() {
        let bounds = CloseUpRegion(center: CGPoint(x: Double.nan, y: Double.infinity),
                                   fraction: .nan).bounds
        #expect(bounds == CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25))
    }

    @Test @MainActor func regionChoicesDoNotTransferBetweenFrames() {
        let a = CloseUpFrame(id: URL(filePath: "/tmp/a.jpg"), name: "a", revision: UUID())
        let b = CloseUpFrame(id: URL(filePath: "/tmp/b.jpg"), name: "b", revision: UUID())
        let model = CloseUpModel()
        let chosen = CloseUpRegion(center: CGPoint(x: 0.1, y: 0.8), fraction: 0.2)
        model.setRegion(chosen, for: a.id)
        #expect(model.region(for: b.id) == CloseUpRegion())
        model.retainFrames([a, b])
        #expect(model.region(for: a.id) == chosen)
        model.retainFrames([b])
        #expect(model.region(for: a.id) == CloseUpRegion())
    }

    @Test @MainActor func adapterSuppliesEverySelectedImageInBrowserOrder() {
        let a = BrowserFileItem(url: URL(filePath: "/tmp/a.jpg"))
        let b = BrowserFileItem(url: URL(filePath: "/tmp/b.jpg"))
        let c = BrowserFileItem(url: URL(filePath: "/tmp/c.jpg"))
        let selection = SelectionModel()
        selection.replaceDisplayedFiles([a, b, c])
        selection.selectOnlyFile(a)
        selection.extendFileSelection(to: c)
        // Moving the active preview must not limit the panel to the active image.
        selection.selectedFileID = b.id
        let frames = selection.selectedFiles.map(\.closeUpFrame)
        #expect(frames.map(\.id) == [a.url, b.url, c.url])
        #expect(frames.map(\.revision) == [a.id, b.id, c.id])
    }

    @Test @MainActor func changedSourceInvalidatesManualRegion() {
        let frame = CloseUpFrame(id: URL(filePath: "/tmp/a.jpg"), name: "a", revision: UUID())
        let model = CloseUpModel()
        model.retainFrames([frame])
        model.setRegion(CloseUpRegion(center: .zero, fraction: 0.1), for: frame.id)
        model.retainFrames([CloseUpFrame(id: frame.id, name: frame.name, revision: UUID())])
        #expect(model.region(for: frame.id) == CloseUpRegion())
    }

    @Test @MainActor func lateResultCannotReplaceNewerRequest() async throws {
        let renderer = HeldCloseUpRenderer()
        let model = CloseUpCardModel()
        let a = request("a"), b = request("b")
        let first = Task { await model.load(a, using: renderer) }
        await renderer.waitForRequest(a.frame.id)
        let second = Task { await model.load(b, using: renderer) }
        await renderer.waitForRequest(b.frame.id)
        await renderer.finish(b.frame.id, label: "new")
        await second.value
        #expect(model.render?.sourceLabel == "new")
        await renderer.finish(a.frame.id, label: "old")
        await first.value
        #expect(model.render?.sourceLabel == "new")
        model.release()
        #expect(model.render == nil)
    }

    @Test @MainActor func regionRefreshKeepsOverviewAvailableForDragging() async {
        let renderer = HeldCloseUpRenderer()
        let model = CloseUpCardModel()
        let initial = request("drag")
        let first = Task { await model.load(initial, using: renderer) }
        await renderer.waitForRequest(initial.frame.id)
        await renderer.finish(initial.frame.id, label: "initial")
        await first.value
        let moved = CloseUpRequest(frame: initial.frame,
            region: CloseUpRegion(center: CGPoint(x: 0.7, y: 0.6), fraction: 0.25),
            mode: initial.mode, displayScale: initial.displayScale)
        let refresh = Task { await model.load(moved, using: renderer) }
        await renderer.waitForRequest(initial.frame.id)
        #expect(model.isLoading)
        #expect(model.render?.sourceLabel == "initial")
        await renderer.finish(initial.frame.id, label: "moved")
        await refresh.value
        #expect(model.render?.sourceLabel == "moved")
        #expect(!model.isLoading)
    }

    @Test @MainActor func disappearingCardRejectsUncooperativeCompletion() async {
        let renderer = HeldCloseUpRenderer()
        let model = CloseUpCardModel()
        let input = request("cancelled")
        let task = Task { await model.load(input, using: renderer) }
        await renderer.waitForRequest(input.frame.id)
        model.release()
        task.cancel()
        await renderer.finish(input.frame.id, label: "late")
        await task.value
        #expect(model.render == nil)
        #expect(!model.isLoading)
    }

    private func request(_ name: String) -> CloseUpRequest {
        CloseUpRequest(frame: CloseUpFrame(id: URL(filePath: "/tmp/\(name).jpg"), name: name, revision: UUID()),
                       region: CloseUpRegion(), mode: .fitRegion, displayScale: 2)
    }
}

private actor HeldCloseUpRenderer: CloseUpRendering {
    private var pending: [URL: CheckedContinuation<CloseUpRender, any Error>] = [:]
    private var arrivals: [URL: CheckedContinuation<Void, Never>] = [:]

    func render(_ request: CloseUpRequest) async throws -> CloseUpRender {
        try await withCheckedThrowingContinuation { continuation in
            pending[request.frame.id] = continuation
            arrivals.removeValue(forKey: request.frame.id)?.resume()
        }
    }

    func waitForRequest(_ id: URL) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { arrivals[id] = $0 }
    }

    func finish(_ id: URL, label: String) {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        pending.removeValue(forKey: id)?.resume(returning: CloseUpRender(
            crop: image, overview: image, sourceWidth: 8, sourceHeight: 8,
            sourceLabel: label, displayedBounds: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
}
