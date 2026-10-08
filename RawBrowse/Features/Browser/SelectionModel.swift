import Foundation
import Observation

@Observable @MainActor
final class SelectionModel {
    private(set) var displayedFiles: [BrowserFileItem] = []
    private var filesByID: [BrowserFileItem.ID: BrowserFileItem] = [:]
    var selectedFileID: BrowserFileItem.ID?
    var selectedFileIDs: Set<BrowserFileItem.ID> = []
    @ObservationIgnored private var selectionAnchorFileID: BrowserFileItem.ID?
    var selectedFile: BrowserFileItem? {
        selectedFileID.flatMap { filesByID[$0] }
    }

    var selectedFiles: [BrowserFileItem] {
        displayedFiles.filter { selectedFileIDs.contains($0.id) }
    }

    func replaceDisplayedFiles(_ files: [BrowserFileItem], selectFirst: Bool = false) {
        displayedFiles = files
        filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if selectFirst {
            selectedFileID = files.first?.id
            selectedFileIDs = Set(files.first.map { [$0.id] } ?? [])
            selectionAnchorFileID = files.first?.id
        } else {
            selectedFileIDs.formIntersection(filesByID.keys)
            if let id = selectedFileID, filesByID[id] == nil {
                selectedFileID = selectedFiles.first?.id
            }
            if let id = selectionAnchorFileID, filesByID[id] == nil {
                selectionAnchorFileID = selectedFileID
            }
        }
    }

    func clear() {
        selectedFileID = nil
        selectedFileIDs = []
        selectionAnchorFileID = nil
    }

    @discardableResult
    func navigateSelection(by delta: Int) -> BrowserFileItem? {
        guard let selectedFile, let index = displayedFiles.firstIndex(of: selectedFile),
              displayedFiles.indices.contains(index + delta) else { return nil }
        let next = displayedFiles[index + delta]
        selectOnlyFile(next)
        return next
    }

    func selectOnlyFile(_ file: BrowserFileItem) {
        selectedFileID = file.id
        selectedFileIDs = [file.id]
        selectionAnchorFileID = file.id
    }

    func toggleFileSelection(_ file: BrowserFileItem) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
            if selectedFileID == file.id {
                selectedFileID = selectedFiles.first?.id
            }
        } else {
            selectedFileIDs.insert(file.id)
            selectedFileID = file.id
            selectionAnchorFileID = file.id
        }

        if selectedFileIDs.isEmpty {
            selectedFileID = nil
            selectionAnchorFileID = nil
        }
    }

    func extendFileSelection(to file: BrowserFileItem) {
        guard let anchorID = selectionAnchorFileID ?? selectedFileID,
              let anchorIndex = displayedFiles.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = displayedFiles.firstIndex(of: file)
        else {
            selectOnlyFile(file)
            return
        }

        let bounds = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
        selectedFileIDs = Set(displayedFiles[bounds].map(\.id))
        selectedFileID = file.id
    }
}
