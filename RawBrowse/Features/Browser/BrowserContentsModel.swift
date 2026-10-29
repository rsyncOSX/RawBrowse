import Foundation
import Observation

@Observable @MainActor
final class BrowserContentsModel {
    var selectedFolder: BrowserFolderItem?
    var files: [BrowserFileItem] = [] {
        didSet { filesChanged?() }
    }

    private(set) var isScanning = false
    private(set) var scanError: String?
    var isCreatingThumbnails = false
    var isSidebarSelectionEnabled: Bool {
        !isCreatingThumbnails
    }

    @ObservationIgnored private let scanRunner = LatestTaskRunner()
    @ObservationIgnored private let discover: @MainActor (URL) async throws -> ([BrowserFolderItem], [BrowserFileItem])
    @ObservationIgnored var filesChanged: (@MainActor () -> Void)?
    @ObservationIgnored var childrenDiscovered: (@MainActor (BrowserFolderItem, [BrowserFolderItem]) -> Void)?
    @ObservationIgnored var scanFinished: (@MainActor () -> Void)?

    init(discover: @escaping @MainActor (URL) async throws -> ([BrowserFolderItem], [BrowserFileItem]) = { url in
        async let folders = BrowserImageLoader.shared.discoverFolders(at: url)
        async let files = BrowserImageLoader.shared.discoverSupportedFiles(at: url)
        return try await (folders, files)
    }) {
        self.discover = discover
    }

    @discardableResult
    func scan(_ folder: BrowserFolderItem, access: CatalogAccessLease?) -> Task<Void, Never> {
        selectedFolder = folder
        scanError = nil
        files = []
        isCreatingThumbnails = false
        isScanning = true
        return scanRunner.start { [self] token in
            defer { withExtendedLifetime(access) {} }
            defer {
                if scanRunner.isCurrent(token) {
                    isScanning = false
                }
            }
            do {
                let diagnostic = BrowserPerformance.begin("scan.discoveryAndPublication", folder.url)
                defer { diagnostic?.end(Task.isCancelled ? "cancelled" : "finished") }
                let (children, discoveredFiles) = try await discover(folder.url)
                guard !Task.isCancelled, scanRunner.isCurrent(token) else { return }
                childrenDiscovered?(folder, children)
                files = discoveredFiles
                scanFinished?()
            } catch {
                guard !Task.isCancelled, scanRunner.isCurrent(token) else { return }
                scanError = "Could not read \(folder.url.path): \(error.localizedDescription)"
            }
        }
    }

    func clear() {
        scanRunner.cancel()
        scanError = nil
        isScanning = false
        isCreatingThumbnails = false
        selectedFolder = nil
        files = []
    }
}
