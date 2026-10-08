import Foundation
import Observation

@Observable @MainActor
final class SettingsModel {
    var values = BrowserSettings()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let load: @MainActor () async -> BrowserSettings
    @ObservationIgnored private let save: @MainActor (BrowserSettings) async -> Void

    init(
        load: @escaping @MainActor () async -> BrowserSettings = { await BrowserSettingsStore.load() },
        save: @escaping @MainActor (BrowserSettings) async -> Void = { await BrowserSettingsStore.save($0) },
    ) {
        self.load = load
        self.save = save
    }

    func loadSettings() async {
        values = await load()
        // Downloaded models are the only model source; discard legacy overrides.
        values.clipModelPath = nil
        values.clipModelBookmarkData = nil
        values.sam3ModelPath = nil
        values.sam3ModelBookmarkData = nil
        persistSettings()
        await MemoryImageCache.shared.apply(settings: values)
    }

    @discardableResult
    func persistSettings() -> Task<Void, Never> {
        let snapshot = values
        let previous = saveTask
        let save = save
        let task = Task {
            await previous?.value
            await save(snapshot)
        }
        saveTask = task
        return task
    }
}
