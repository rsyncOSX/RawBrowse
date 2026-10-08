import Foundation
import Observation

@Observable @MainActor
final class SidebarPresentationModel {
    let catalog: CatalogStore
    private(set) var visibleSidebarFolders: [BrowserFolderItem] = []
    private(set) var depthByID: [BrowserFolderItem.ID: Int] = [:]
    var expandedFolderIDs: Set<BrowserFolderItem.ID> = [] {
        didSet { rebuildVisibleFolders() }
    }

    init(catalog: CatalogStore) {
        self.catalog = catalog
    }

    func hierarchyDidChange() {
        let known = Set(catalog.rootFolders.map(\.id) + catalog.folderChildren.values.flatMap { $0.map(\.id) })
        let expanded = expandedFolderIDs.intersection(known)
        if expanded != expandedFolderIDs {
            expandedFolderIDs = expanded
        } else {
            rebuildVisibleFolders()
        }
    }

    func isFolderExpanded(_ folder: BrowserFolderItem) -> Bool {
        expandedFolderIDs.contains(folder.id)
    }

    func setFolder(_ folder: BrowserFolderItem, expanded: Bool) {
        if expanded {
            expandedFolderIDs.insert(folder.id)
            catalog.loadChildrenIfNeeded(for: folder)
        } else {
            expandedFolderIDs.remove(folder.id)
        }
    }

    private func rebuildVisibleFolders() {
        var folders: [BrowserFolderItem] = []
        var depths: [BrowserFolderItem.ID: Int] = [:]

        func appendVisibleFolder(_ folder: BrowserFolderItem, depth: Int) {
            depths[folder.id] = depth
            folders.append(folder)
            guard isFolderExpanded(folder) else { return }
            catalog.children(of: folder).forEach { appendVisibleFolder($0, depth: depth + 1) }
        }

        catalog.rootFolders.forEach { appendVisibleFolder($0, depth: 0) }
        visibleSidebarFolders = folders
        depthByID = depths
    }

    @discardableResult
    func destination(by offset: Int, selectedFolder: BrowserFolderItem?, enabled: Bool) -> BrowserFolderItem? {
        guard enabled, offset != 0 else { return nil }

        let folders = visibleSidebarFolders
        guard !folders.isEmpty else { return nil }

        let destinationIndex: Int = if let selectedFolder,
                                       let selectedIndex = folders.firstIndex(where: { $0.id == selectedFolder.id })
        {
            selectedIndex + offset
        } else {
            offset > 0 ? folders.startIndex : folders.index(before: folders.endIndex)
        }

        guard folders.indices.contains(destinationIndex) else { return nil }
        return folders[destinationIndex]
    }

    @discardableResult
    func expandSelectedSidebarFolder(_ selectedFolder: BrowserFolderItem?, enabled: Bool) -> Bool {
        guard enabled,
              let selectedFolder,
              !isFolderExpanded(selectedFolder),
              !catalog.hasLoadedChildren(for: selectedFolder) || !catalog.children(of: selectedFolder).isEmpty
        else { return false }

        setFolder(selectedFolder, expanded: true)
        return true
    }

    @discardableResult
    func collapseSelectedSidebarFolder(_ selectedFolder: BrowserFolderItem?, enabled: Bool) -> Bool {
        guard enabled,
              let selectedFolder,
              isFolderExpanded(selectedFolder)
        else { return false }

        setFolder(selectedFolder, expanded: false)
        return true
    }
}
