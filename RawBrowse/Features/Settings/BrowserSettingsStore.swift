import Foundation

enum BrowserSettingsStore {
    static func load(from url: URL = settingsURL) async throws -> BrowserSettings {
        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url)
            }.value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return BrowserSettings()
        }
        return try JSONDecoder().decode(BrowserSettings.self, from: data)
    }

    static func save(_ settings: BrowserSettings, to url: URL = settingsURL) async throws {
        let data = try JSONEncoder().encode(settings)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: url, options: .atomic)
        }.value
    }

    private static var settingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("RawBrowse", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
