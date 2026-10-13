import Foundation
import Observation

@Observable @MainActor
final class SettingsModel {
    var values = BrowserSettings()
    private(set) var settingsError: String?
    private(set) var hasUnsavedChanges = false
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored private var saveRevision = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let load: @MainActor () async throws -> BrowserSettings
    @ObservationIgnored private let save: @MainActor (BrowserSettings) async throws -> Void

    init(
        load: @escaping @MainActor () async throws -> BrowserSettings = { try await BrowserSettingsStore.load() },
        save: @escaping @MainActor (BrowserSettings) async throws -> Void = { try await BrowserSettingsStore.save($0) },
    ) {
        self.load = load
        self.save = save
    }

    func loadSettings() async {
        await saveTask?.value
        do {
            let loaded = try await load()
            values = loaded
            canPersist = true
            settingsError = nil
            // Remove legacy overrides only after a successful read.
            values.clipModelPath = nil
            values.clipModelBookmarkData = nil
            values.sam3ModelPath = nil
            values.sam3ModelBookmarkData = nil
            persistSettings()
        } catch {
            canPersist = false
            settingsError = "Could not load settings: \(error.localizedDescription)"
        }
        await MemoryImageCache.shared.apply(settings: values)
    }

    func retryPersistence() async {
        if canPersist { await persistSettings().value }
        else { await loadSettings() }
    }

    func finishSaving() async { await saveTask?.value }

    @discardableResult
    func persistSettings() -> Task<Void, Never> {
        guard canPersist else { return Task {} }
        let revision = UUID()
        saveRevision = revision
        hasUnsavedChanges = true
        let snapshot = values
        let previous = saveTask
        let save = save
        let task = Task {
            await previous?.value
            do {
                try await save(snapshot)
                if saveRevision == revision {
                    hasUnsavedChanges = false
                    settingsError = nil
                }
            } catch {
                if saveRevision == revision {
                    settingsError = "Could not save settings: \(error.localizedDescription)"
                }
            }
        }
        saveTask = task
        return task
    }
}
