import Foundation
import Observation

@Observable @MainActor
final class SettingsModel {
    enum LoadState { case unread, loading, ready, failed }
    private(set) var loadState: LoadState
    var isReady: Bool { loadState == .ready }
    private var storedValues: BrowserSettings
    var values: BrowserSettings {
        get { storedValues }
        set {
            guard isReady else { return }
            storedValues = newValue
        }
    }
    private(set) var settingsError: String?
    private(set) var hasUnsavedChanges = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let load: @MainActor () async throws -> BrowserSettings
    @ObservationIgnored private let save: @MainActor (BrowserSettings) async throws -> Void

    init(
        initialValues: BrowserSettings? = nil,
        load: @escaping @MainActor () async throws -> BrowserSettings = { try await BrowserSettingsStore.load() },
        save: @escaping @MainActor (BrowserSettings) async throws -> Void = { try await BrowserSettingsStore.save($0) },
    ) {
        storedValues = initialValues ?? BrowserSettings()
        loadState = initialValues == nil ? .unread : .ready
        self.load = load
        self.save = save
    }

    func loadSettings() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !isReady else { return }
        loadState = .loading
        let task = Task { [self] in
            defer { loadTask = nil }
            await saveTask?.value
            do {
                var loaded = try await load()
                // Remove legacy overrides only after a successful read.
                loaded.clipModelPath = nil
                loaded.clipModelBookmarkData = nil
                loaded.sam3ModelPath = nil
                loaded.sam3ModelBookmarkData = nil
                storedValues = loaded
                loadState = .ready
                settingsError = nil
                persistSettings()
            } catch {
                loadState = .failed
                settingsError = "Could not load settings: \(error.localizedDescription)"
            }
            await MemoryImageCache.shared.apply(settings: values)
        }
        loadTask = task
        await task.value
    }

    func retryPersistence() async {
        if isReady {
            await persistSettings().value
        } else {
            await loadSettings()
        }
    }

    func finishSaving() async {
        await loadTask?.value
        await saveTask?.value
    }

    @discardableResult
    func persistSettings() -> Task<Void, Never> {
        guard isReady else { return Task {} }
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
