import Foundation
import PhotoEvidenceContracts

/// Source metadata is read off the UI actor and protected by catalog access.
/// Revisions are stable across launches, unlike BrowserFileItem's session UUID.
enum BrowserCloseUpFrameAdapter {
    @concurrent static func frames(for files: [BrowserFileItem]) async -> [CloseUpFrame] {
        var result: [CloseUpFrame] = []
        for file in files {
            guard !Task.isCancelled else { return [] }
            let access = await CatalogAccess.shared.lease(for: file.url)
            let revision = ImageSourceFingerprint.key(for: file.url)
            withExtendedLifetime(access) {}
            result.append(CloseUpFrame(id: file.url, name: file.name, revision: revision))
        }
        return result
    }
}
