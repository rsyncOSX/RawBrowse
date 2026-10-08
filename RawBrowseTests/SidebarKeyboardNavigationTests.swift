import Foundation
@testable import RawBrowse
import Testing

@Suite("Sidebar keyboard navigation")
struct SidebarKeyboardNavigationTests {
    @Test
    func `Visible folders follow expanded catalog hierarchy`() {
        let viewModel = FileBrowserViewModel()
        let catalog = folder("catalog")
        let first = folder("catalog/first")
        let nested = folder("catalog/first/nested")
        let second = folder("catalog/second")

        viewModel.catalog.rootFolders = [catalog]
        viewModel.catalog.folderChildren[catalog.id] = [first, second]
        viewModel.catalog.folderChildren[first.id] = [nested]

        #expect(viewModel.sidebar.visibleSidebarFolders.map(\.id) == [catalog.id])

        viewModel.sidebar.expandedFolderIDs = [catalog.id]
        #expect(viewModel.sidebar.visibleSidebarFolders.map(\.id) == [catalog.id, first.id, second.id])

        viewModel.sidebar.expandedFolderIDs.insert(first.id)
        #expect(viewModel.sidebar.visibleSidebarFolders.map(\.id) == [catalog.id, first.id, nested.id, second.id])
    }

    @Test
    func `Horizontal arrows expand and collapse the selected folder`() {
        let viewModel = FileBrowserViewModel()
        let catalog = folder("catalog")
        let child = folder("catalog/child")

        viewModel.catalog.rootFolders = [catalog]
        viewModel.catalog.folderChildren[catalog.id] = [child]
        viewModel.contents.selectedFolder = catalog

        #expect(viewModel.sidebar.expandSelectedSidebarFolder(viewModel.contents.selectedFolder, enabled: true))
        #expect(viewModel.sidebar.isFolderExpanded(catalog))
        #expect(!viewModel.sidebar.expandSelectedSidebarFolder(viewModel.contents.selectedFolder, enabled: true))

        #expect(viewModel.sidebar.collapseSelectedSidebarFolder(viewModel.contents.selectedFolder, enabled: true))
        #expect(!viewModel.sidebar.isFolderExpanded(catalog))
        #expect(!viewModel.sidebar.collapseSelectedSidebarFolder(viewModel.contents.selectedFolder, enabled: true))
    }

    @Test
    func `Leaf folders do not expand`() {
        let viewModel = FileBrowserViewModel()
        let leaf = folder("catalog/leaf")

        viewModel.catalog.rootFolders = [leaf]
        viewModel.catalog.folderChildren[leaf.id] = []
        viewModel.contents.selectedFolder = leaf

        #expect(!viewModel.sidebar.expandSelectedSidebarFolder(viewModel.contents.selectedFolder, enabled: true))
        #expect(!viewModel.sidebar.isFolderExpanded(leaf))
    }

    private func folder(_ path: String) -> BrowserFolderItem {
        BrowserFolderItem(url: URL(filePath: "/tmp/RawBrowseTests/\(path)", directoryHint: .isDirectory))
    }
}
