import Foundation
@testable import RawBrowse
import Testing

@Suite("Browser transitions")
@MainActor
struct BrowserTransitionTests {
    @Test
    func `Range selection follows displayed search order`() {
        let model = FileBrowserViewModel()
        let files = (0 ..< 4).map { BrowserFileItem(url: URL(filePath: "/tmp/photo-\($0).jpg")) }
        model.contents.files = files
        model.selection.selectOnlyFile(files[1])
        model.selection.extendFileSelection(to: files[3])
        #expect(model.selection.selectedFileIDs == Set(files[1 ... 3].map(\.id)))
        model.selection.toggleFileSelection(files[3])
        #expect(model.selection.selectedFileID == files[1].id)
        model.selection.toggleFileSelection(files[1])
        model.selection.toggleFileSelection(files[2])
        #expect(model.selection.selectedFileID == nil)
        #expect(model.selection.selectedFileIDs.isEmpty)
    }

    @Test
    func `Clearing search restores the first folder file`() {
        let model = FileBrowserViewModel()
        let file = BrowserFileItem(url: URL(filePath: "/tmp/folder-photo.jpg"))
        model.contents.files = [file]
        model.clip.semanticSearchActive = true
        model.clip.semanticSearchQuery = "birds"
        model.clip.similaritySearchAnchorName = "anchor"
        model.clip.clearSemanticSearchResults(keepingQuery: true)
        #expect(model.selection.selectedFileID == file.id)
        #expect(model.selection.selectedFileIDs == [file.id])
        #expect(!model.clip.semanticSearchActive)
        #expect(model.clip.similaritySearchAnchorName == nil)
        #expect(model.clip.semanticSearchQuery == "birds")
    }

    @Test
    func `Navigation bounds preserve selection`() {
        let model = FileBrowserViewModel()
        let file = BrowserFileItem(url: URL(filePath: "/tmp/only-photo.jpg"))
        model.contents.files = [file]
        model.selection.selectOnlyFile(file)
        model.navigateSelection(by: -1)
        model.navigateSelection(by: 1)
        #expect(model.selection.selectedFileID == file.id)
        #expect(model.selection.selectedFileIDs == [file.id])
    }
}
