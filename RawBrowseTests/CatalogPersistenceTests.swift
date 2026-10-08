import Foundation
@testable import RawBrowse
import Testing

@MainActor
struct CatalogPersistenceTests {
    @Test
    func `missing catalog is empty but corrupt and unreadable catalogs throw`() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalogs.json")
        #expect(try await RememberedCatalogStore.load(from: file).isEmpty)
        try Data("invalid json".utf8).write(to: file)
        await #expect(throws: DecodingError.self) { try await RememberedCatalogStore.load(from: file) }
        await #expect(throws: (any Error).self) { try await RememberedCatalogStore.load(from: root) }
    }

    @Test
    func `failed load prevents overwriting original bytes when adding a folder`() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalogs.json")
        let original = Data("corrupt but recoverable".utf8)
        try original.write(to: file)
        let store = CatalogStore(load: { try await RememberedCatalogStore.load(from: file) },
                                 save: { try await RememberedCatalogStore.save($0, to: file) },
                                 remember: { RememberedCatalog(path: $0.path, bookmarkData: Data([1])) },
                                 openAccess: { _ in true }, closeAccess: { _ in }, lease: { _ in nil },
                                 discoverFolders: { _ in [] })
        await store.loadRememberedCatalogs()
        _ = store.addRootFolder(root)
        await store.saveRememberedCatalogs()
        #expect(try Data(contentsOf: file) == original)
        #expect(store.catalogError != nil)
        let offline = RememberedCatalog(path: "/Volumes/Offline/Photos", bookmarkData: Data([9]))
        try await RememberedCatalogStore.save([offline], to: file)
        await store.loadRememberedCatalogs()
        let recovered = try await RememberedCatalogStore.load(from: file)
        #expect(Set(recovered.map(\.path)) == Set([root.path, offline.path]))
    }

    @Test
    func `unavailable entries survive subsequent saves`() async {
        let unavailable = RememberedCatalog(path: "/Volumes/Offline/Photos", bookmarkData: Data([1]))
        var saved: [RememberedCatalog] = []
        let store = CatalogStore(load: { [unavailable] }, save: { saved = $0 },
                                 resolve: { _ in throw CocoaError(.fileReadNoPermission) })
        await store.loadRememberedCatalogs()
        await store.saveRememberedCatalogs()
        #expect(saved.map(\.path) == [unavailable.path])
        #expect(store.rootFolders.isEmpty)
        #expect(store.catalogError != nil)
    }

    @Test
    func `stale bookmark is renewed and saved while access is active`() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var accessActive = false
        var saved: [RememberedCatalog] = []
        let store = CatalogStore(
            load: { [RememberedCatalog(path: root.path, bookmarkData: Data([1]))] },
            save: { saved = $0 }, resolve: { _ in (root, true) },
            remember: { url in
                #expect(accessActive)
                return RememberedCatalog(path: url.path, bookmarkData: Data([2]))
            }, openAccess: { _ in accessActive = true; return true }, closeAccess: { _ in },
            lease: { _ in nil }, discoverFolders: { _ in [] },
        )
        await store.loadRememberedCatalogs()
        #expect(saved.first?.bookmarkData == Data([2]))
        #expect(store.rootFolders.count == 1)
        // Retrying must not replace the renewed bookmark with the previous in-memory value.
        await store.loadRememberedCatalogs()
        #expect(saved.first?.bookmarkData == Data([2]))
    }

    @Test
    func `save failure is reported`() async {
        let store = CatalogStore(load: { [] }, save: { _ in throw CocoaError(.fileWriteNoPermission) })
        await store.loadRememberedCatalogs()
        await store.saveRememberedCatalogs()
        #expect(store.catalogError?.contains("Could not save folders") == true)
    }
}
