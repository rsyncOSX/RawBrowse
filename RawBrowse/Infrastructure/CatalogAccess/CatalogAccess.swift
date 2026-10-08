import Foundation

/// One balanced grant, shared by the catalog session and its in-flight work.
/// Releasing the session's reference never revokes a worker's grant.
nonisolated final class CatalogAccessLease: Sendable {
    let url: URL
    private let stopAccess: @Sendable (URL) -> Void

    init?(
        url: URL,
        startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        guard startAccess(url) else { return nil }
        self.url = url
        self.stopAccess = stopAccess
    }

    deinit { stopAccess(url) }
}

/// Image workers look up the root grant before launching their owned decode.
@MainActor
final class CatalogAccess {
    static let shared = CatalogAccess()
    private var sessions: [URL: CatalogAccessLease] = [:]

    func open(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        if sessions[url] != nil { return true }
        guard let lease = CatalogAccessLease(url: url) else { return false }
        sessions[url] = lease
        return true
    }

    func lease(for url: URL) -> CatalogAccessLease? {
        let url = url.standardizedFileURL
        return sessions.values
            .filter { url.isEqualOrDescendant(of: $0.url) }
            .max { $0.url.pathComponents.count < $1.url.pathComponents.count }
    }

    func close(_ url: URL) {
        sessions[url.standardizedFileURL] = nil
    }
}
