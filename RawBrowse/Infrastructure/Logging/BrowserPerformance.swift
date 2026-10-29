import AppKit
import Foundation
import Synchronization

/// Opt-in diagnostics only. Intervals measure delivery/work, never painted frames.
nonisolated enum BrowserPerformance {
    private static let output: Mutex<FileHandle?> = {
        guard let path = ProcessInfo.processInfo.environment["RAWBROWSE_PERFORMANCE_LOG"] else { return Mutex(nil) }
        // An inherited stderr descriptor permits capture without widening sandbox access.
        if path == "-" { return Mutex(.standardError) }
        guard path.hasPrefix("/") else { return Mutex(nil) }
        FileManager.default.createFile(atPath: path, contents: nil)
        return Mutex(try? FileHandle(forWritingTo: URL(fileURLWithPath: path)))
    }()

    static var isEnabled: Bool { output.withLock { $0 != nil } }

    private static func write(_ record: [String: Any]) {
        guard isEnabled,
              var data = serializedRecord(record) else { return }
        data.append(0x0A)
        output.withLock { handle in try? handle?.write(contentsOf: data) }
    }

    static func serializedRecord(_ record: [String: Any]) -> Data? {
        // Foundation can raise an Objective-C exception for unsupported Swift values.
        guard JSONSerialization.isValidJSONObject(record) else { return nil }
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    static func workspaceSettingsFields(_ settings: BrowserSettings) -> [String: Any] {
        ["grid_pixels": settings.thumbnailSizeGrid, "preview_pixels": settings.thumbnailSizePreview,
         "full_size_pixels": "native", "grid_cache_mb": settings.gridCacheSizeMB,
         "memory_cache_mb": settings.memoryCacheSizeMB,
         "max_cached_previews": settings.maxCachedExtractedJPGs,
         "selected_clip_model": settings.selectedCLIPModel.downloadID.rawValue]
    }

    static func event(_ name: String, fields: [String: Any]) {
        write(["event": name, "time": ProcessInfo.processInfo.systemUptime, "fields": fields])
    }

    @MainActor static func recordWorkspace(settings: BrowserSettings) {
        guard isEnabled else { return }
        let windows: [[String: Any]] = NSApplication.shared.windows.filter(\.isVisible).map { window in
            ["title": window.title, "width": window.frame.width, "height": window.frame.height,
             "content_width": window.contentLayoutRect.width, "content_height": window.contentLayoutRect.height,
             "backing_scale": window.backingScaleFactor]
        }
        var fields = workspaceSettingsFields(settings)
        fields["windows"] = windows
        fields["executable"] = Bundle.main.executableURL?.path ?? "unknown"
        event("workspace.configuration", fields: fields)
    }

    static func cacheDirectory(_ component: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment["RAWBROWSE_PERFORMANCE_CACHE_ROOT"],
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(component, isDirectory: true)
    }

    struct Interval: Sendable {
        let id = UUID().uuidString
        let stage: String
        let path: String
        let details: [String: String]
        let start = ProcessInfo.processInfo.systemUptime

        func end(_ result: String = "finished") {
            let finish = ProcessInfo.processInfo.systemUptime
            let record: [String: Any] = ["id": id, "stage": stage, "path": path, "details": details,
                "start": start, "end": finish, "duration_ms": (finish - start) * 1000,
                "result": result]
            // A synchronous lock protects the handle; no suspension or actor hop occurs inside it.
            write(record)
        }
    }

    static func begin(_ stage: String, _ url: URL, details: [String: String] = [:]) -> Interval? {
        guard isEnabled else { return nil }
        return Interval(stage: stage, path: url.path, details: details)
    }
}
