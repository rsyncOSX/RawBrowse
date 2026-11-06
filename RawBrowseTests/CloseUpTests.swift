import Foundation
import Testing
import PhotoEvidenceContracts
import PhotoEvidenceUI
@testable import RawBrowse

@Suite("Close-ups host integration") @MainActor
struct CloseUpTests {
    @Test func adapterIncludesAllSelectedImagesWithStableSourceRevisions() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { directory.appending(path: $0) }
        for url in urls { try Data([1, 2, 3]).write(to: url) }
        let firstFiles = urls.map { BrowserFileItem(url: $0) }
        let selection = SelectionModel()
        selection.replaceDisplayedFiles(firstFiles)
        selection.selectOnlyFile(firstFiles[0])
        selection.extendFileSelection(to: firstFiles[2])
        selection.selectedFileID = firstFiles[1].id
        let first = await BrowserCloseUpFrameAdapter.frames(for: selection.selectedFiles)
        let reopened = await BrowserCloseUpFrameAdapter.frames(for: urls.map { BrowserFileItem(url: $0) })
        #expect(first.map(\.id) == urls)
        #expect(first.map(\.revision) == reopened.map(\.revision))
        try Data([9, 8, 7, 6]).write(to: urls[0])
        let replaced = await BrowserCloseUpFrameAdapter.frames(for: firstFiles)
        #expect(first[0].revision != replaced[0].revision)
    }

    @Test func preferencesRestoreRegionsInNewModelAndRejectChangedSource() throws {
        let suite = "PhotoEvidenceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frame = CloseUpFrame(id: URL(filePath: "/fixture/a.jpg"), name: "a", revision: "stable")
        let first = CloseUpModel(storage: BrowserCloseUpRegionStore(defaults: defaults))
        first.updateFrames([frame])
        let region = CloseUpRegion(center: CGPoint(x: 0.2, y: 0.8), fraction: 0.2)
        first.setRegion(region, for: frame.id)
        let second = CloseUpModel(storage: BrowserCloseUpRegionStore(defaults: defaults))
        second.updateFrames([frame])
        #expect(second.region(for: frame.id) == region)
        second.updateFrames([CloseUpFrame(id: frame.id, name: frame.name, revision: "changed")])
        #expect(second.region(for: frame.id) == CloseUpRegion())
    }
}
