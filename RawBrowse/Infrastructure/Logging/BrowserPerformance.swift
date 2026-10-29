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

    static func cacheDirectory(_ component: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment["RAWBROWSE_PERFORMANCE_CACHE_ROOT"],
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(component, isDirectory: true)
    }

    struct Interval: Sendable {
        let id = UUID().uuidString
        let stage: String
        let path: String
        let start = ProcessInfo.processInfo.systemUptime

        func end(_ result: String = "finished") {
            let finish = ProcessInfo.processInfo.systemUptime
            let record: [String: Any] = ["id": id, "stage": stage, "path": path,
                "start": start, "end": finish, "duration_ms": (finish - start) * 1000,
                "result": result]
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            // A synchronous lock protects the handle; no suspension or actor hop occurs inside it.
            output.withLock { handle in try? handle?.write(contentsOf: data) }
        }
    }

    static func begin(_ stage: String, _ url: URL) -> Interval? {
        guard output.withLock({ $0 != nil }) else { return nil }
        return Interval(stage: stage, path: url.path)
    }
}
