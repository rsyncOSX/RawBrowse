import CryptoKit
import Foundation
import PhotoEvidenceContracts

/// Small app-owned preference records. No RAW bytes, sidecars or AI data change.
@MainActor final class BrowserCloseUpRegionStore: CloseUpRegionStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(for frame: CloseUpFrame) throws -> CloseUpRegionRecord? {
        guard let data = defaults.data(forKey: key(frame.id)) else { return nil }
        return try JSONDecoder().decode(CloseUpRegionRecord.self, from: data)
    }

    func save(_ record: CloseUpRegionRecord) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: key(record.sourceID))
    }

    private func key(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "PhotoEvidenceKit.ManualRegion.v1." + digest
    }
}
