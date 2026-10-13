import Darwin
import Foundation

/// Owned by a disk-cache actor. File modification dates persist recency across launches.
nonisolated struct DiskCachePolicy {
    private struct Entry {
        let bytes: Int64
        var lastUsed: Date
    }

    let maximumBytes: Int64
    private var entries: [URL: Entry] = [:]
    private var totalBytes: Int64 = 0

    init(directory: URL, maximumBytes: Int64) throws {
        self.maximumBytes = max(0, maximumBytes)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
        )
        for file in files where file.pathExtension == "jpg" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            entries[file] = Entry(bytes: bytes, lastUsed: values.contentModificationDate ?? .distantPast)
            totalBytes += bytes
        }
        try evictIfNeeded()
    }

    mutating func recordWrite(_ url: URL, bytes: Int) throws {
        totalBytes -= entries[url]?.bytes ?? 0
        entries[url] = Entry(bytes: Int64(bytes), lastUsed: Date())
        totalBytes += Int64(bytes)
        try evictIfNeeded()
    }

    mutating func recordHit(_ url: URL) {
        guard entries[url] != nil else { return }
        let now = Date()
        entries[url]?.lastUsed = now
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    mutating func reset() {
        entries.removeAll()
        totalBytes = 0
    }

    private mutating func evictIfNeeded() throws {
        guard totalBytes > maximumBytes else { return }
        for (url, entry) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // An OS purge already removed this entry.
            }
            entries.removeValue(forKey: url)
            totalBytes -= entry.bytes
            if totalBytes <= maximumBytes {
                break
            }
        }
    }
}

nonisolated enum ImageSourceFingerprint {
    static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            return "\(path):unavailable"
        }
        // ctime changes on in-place writes even when an editor restores mtime and size.
        // Device/inode also distinguish replacement files with preserved metadata.
        return "v2:\(path):\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}
