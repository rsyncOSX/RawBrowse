import Foundation

nonisolated enum RawBrowseAICapabilityStatus: Equatable, Sendable {
    case checking(expectedLocations: [URL])
    case available(location: URL?)
    case missing(expectedLocations: [URL])
    case invalid(location: URL?, reason: String)
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self {
            true
        } else {
            false
        }
    }
}

nonisolated struct BurstGroupSignature: Codable, Hashable, Sendable {
    // Used by synthesized Codable, Hashable, and Equatable for burst identity.
    // periphery:ignore
    let memberKeys: [String]

    init(memberKeys: [String]) {
        self.memberKeys = memberKeys
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    init(files: [BrowserFileItem], catalog: URL?) {
        let keys = files.map { Self.memberKey(for: $0, catalog: catalog) }
        self.init(memberKeys: keys)
    }

    static func memberKey(for file: BrowserFileItem, catalog _: URL?) -> String {
        // Absolute source identity prevents cross-catalog collisions. Include the display
        // identity so results never retain UUIDs belonging to an earlier scan.
        "\(file.id.uuidString):\(ImageSourceFingerprint.key(for: file.url))"
    }
}

nonisolated enum SharpnessScoringSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case embeddedPreview
    case rawDemosaic

    var id: String {
        rawValue
    }
}
