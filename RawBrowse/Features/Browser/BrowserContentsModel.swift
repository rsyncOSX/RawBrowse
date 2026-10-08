import Foundation
import Observation

@Observable @MainActor
final class BrowserContentsModel {
    var selectedFolder: BrowserFolderItem?
    var files: [BrowserFileItem] = [] {
        didSet { filesChanged?() }
    }

    private(set) var isScanning = false
    var isCreatingThumbnails = false
    var isSidebarSelectionEnabled: Bool {
        !isCreatingThumbnails
    }

    @ObservationIgnored private let scanRunner = LatestTaskRunner()
    @ObservationIgnored private let discover: @MainActor (URL) async -> ([BrowserFolderItem], [BrowserFileItem])
    @ObservationIgnored var filesChanged: (@MainActor () -> Void)?
    @ObservationIgnored var childrenDiscovered: (@MainActor (BrowserFolderItem, [BrowserFolderItem]) -> Void)?
    @ObservationIgnored var scanFinished: (@MainActor () -> Void)?

    init(discover: @escaping @MainActor (URL) async -> ([BrowserFolderItem], [BrowserFileItem]) = { url in
        async let folders = BrowserImageLoader.shared.discoverFolders(at: url)
        async let files = BrowserImageLoader.shared.discoverSupportedFiles(at: url)
        return await (folders, files)
    }) {
        self.discover = discover
    }

    @discardableResult
    func scan(_ folder: BrowserFolderItem, access: CatalogAccessLease?) -> Task<Void, Never> {
        selectedFolder = folder
        isCreatingThumbnails = false
        isScanning = true
        return scanRunner.start { [self] token in
            defer { withExtendedLifetime(access) {} }
            defer {
                if scanRunner.isCurrent(token) {
                    isScanning = false
                }
            }
            let (children, discoveredFiles) = await discover(folder.url)
            guard !Task.isCancelled, scanRunner.isCurrent(token) else { return }
            childrenDiscovered?(folder, children)
            files = discoveredFiles
            scanFinished?()
        }
    }

    func clear() {
        scanRunner.cancel()
        isScanning = false
        isCreatingThumbnails = false
        selectedFolder = nil
        files = []
    }
}
