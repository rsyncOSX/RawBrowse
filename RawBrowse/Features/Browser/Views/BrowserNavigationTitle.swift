import Foundation

/// Formatting belongs with browser presentation, independently of loading/state ownership.
enum BrowserNavigationTitle {
    static func make(folder: BrowserFolderItem?, searchActive: Bool, anchorName: String?, resultCount: Int, fileCount: Int) -> String {
        guard let folder else { return "RawBrowse" }
        if searchActive {
            if let anchorName {
                return "Similar to \(anchorName) (\(resultCount) results)"
            }
            return "Semantic Search (\(resultCount) results)"
        }
        return "\(folder.name) (\(fileCount) files)"
    }
}
