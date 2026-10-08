import Foundation

enum RememberedCatalogStore {
    static func load(from fileURL: URL? = nil) async throws -> [RememberedCatalog] {
        let url = fileURL ?? catalogsURL
        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url)
            }.value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder.catalogDecoder.decode([RememberedCatalog].self, from: data)
    }

    static func catalog(for url: URL) -> RememberedCatalog? {
        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        ) else { return nil }

        return RememberedCatalog(
            path: url.path,
            bookmarkData: bookmarkData,
        )
    }

    static func save(_ catalogs: [RememberedCatalog], to fileURL: URL? = nil) async throws {
        let url = fileURL ?? catalogsURL
        let data = try JSONEncoder.prettyCatalogEncoder.encode(catalogs)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }.value
    }

    static func clear() async throws {
        let url = catalogsURL
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    static func resolve(_ catalog: RememberedCatalog) throws -> (url: URL, isStale: Bool) {
        guard let data = catalog.bookmarkData else {
            throw CocoaError(.fileReadNoPermission)
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    private static var catalogsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("RawBrowse", isDirectory: true)
            .appendingPathComponent("catalogs.json")
    }
}

private extension JSONEncoder {
    static var prettyCatalogEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var catalogDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
