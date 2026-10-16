import Foundation
@testable import RawBrowse
import Testing

@MainActor
@Suite("Settings initialization")
struct SettingsInitializationTests {
    @Test
    func unreadAndLoadingSettingsCannotOverwriteExistingValues() async {
        let gate = SettingsLoadGate()
        var reads = 0
        var saved: [Int] = []
        let model = SettingsModel(load: {
            reads += 1
            await gate.wait()
            var loaded = BrowserSettings()
            loaded.semanticSearchLimit = 170
            return loaded
        }, save: { saved.append($0.semanticSearchLimit) })
        model.values.semanticSearchLimit = 10
        await model.persistSettings().value
        #expect(saved.isEmpty)
        #expect(!model.isReady)
        let first = Task { await model.loadSettings() }
        await gate.waitUntilStarted()
        model.values.semanticSearchLimit = 20
        await model.persistSettings().value
        #expect(saved.isEmpty)
        let second = Task { await model.loadSettings() }
        let finish = Task { await model.finishSaving() }
        gate.release()
        await first.value
        await second.value
        await finish.value
        #expect(reads == 1)
        #expect(model.isReady)
        #expect(model.values.semanticSearchLimit == 170)
        #expect(saved == [170])
        model.values.semanticSearchLimit = 180
        await model.persistSettings().value
        #expect(saved == [170, 180])
    }

    @Test
    func failedReadStaysReadOnlyUntilRetrySucceeds() async {
        var fail = true
        var writes = 0
        let model = SettingsModel(load: {
            if fail { throw CocoaError(.fileReadNoPermission) }
            return BrowserSettings()
        }, save: { _ in writes += 1 })
        await model.loadSettings()
        #expect(model.loadState == .failed)
        model.values.semanticSearchLimit = 10
        await model.persistSettings().value
        #expect(writes == 0)
        fail = false
        await model.retryPersistence()
        await model.finishSaving()
        #expect(model.isReady)
        #expect(model.settingsError == nil)
        #expect(writes == 1)
    }

    @Test
    func explicitReadyStoreNeverReadsProductionSettings() async {
        var reads = 0
        var writes = 0
        let model = SettingsModel(initialValues: BrowserSettings(), load: {
            reads += 1
            return BrowserSettings()
        }, save: { _ in writes += 1 })
        await model.loadSettings()
        await model.persistSettings().value
        #expect(reads == 0)
        #expect(writes == 1)
    }

    @Test
    func missingFileInitializesAndMalformedFileIsPreserved() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "settings.json")
        let model = SettingsModel(load: { try await BrowserSettingsStore.load(from: url) },
                                  save: { try await BrowserSettingsStore.save($0, to: url) })
        await model.loadSettings()
        await model.finishSaving()
        #expect(model.isReady)
        #expect(try await BrowserSettingsStore.load(from: url) == BrowserSettings())
        let malformed = Data("broken".utf8)
        try malformed.write(to: url)
        let broken = SettingsModel(load: { try await BrowserSettingsStore.load(from: url) },
                                   save: { try await BrowserSettingsStore.save($0, to: url) })
        await broken.loadSettings()
        await broken.persistSettings().value
        #expect(broken.loadState == .failed)
        #expect(try Data(contentsOf: url) == malformed)
    }
}

@MainActor
private final class SettingsLoadGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
