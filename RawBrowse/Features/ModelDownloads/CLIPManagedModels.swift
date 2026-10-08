import CryptoKit
import Foundation

nonisolated enum CLIPManagedModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case dataComp = "data-comp"
    // case openAI = "openai"

    static let defaultSelection = Self.dataComp

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .dataComp: "DataComp"
            // case .openAI: "OpenAI"
        }
    }

    var downloadID: CLIPModelDownloadID {
        switch self {
        case .dataComp: .clipDataComp
            // case .openAI: .clipOpenAI
        }
    }
}

nonisolated enum CLIPModelDownloadState: Equatable, Sendable {
    case checking
    case unavailable(reason: LocalizedStringResource)
    case licenceRequired
    case notConfigured
    case ready
    case downloading(progress: Double)
    case validating
    case installed(location: URL)
    case removing
    case failed(message: String)

    var isInstalled: Bool {
        if case .installed = self {
            true
        } else {
            false
        }
    }

    var installedLocation: URL? {
        guard case let .installed(location) = self else { return nil }
        return location
    }

    var canStartDownload: Bool {
        switch self {
        case .ready, .failed: true
        case .unavailable, .licenceRequired, .checking, .notConfigured, .downloading, .validating, .installed, .removing: false
        }
    }
}

nonisolated struct CLIPModelDownloadsSnapshot: Equatable, Sendable {
    let states: [CLIPModelDownloadID: CLIPModelDownloadState]
    let managedModelLocations: [CLIPModelDownloadID: URL]
    let acceptedLicenceModelIDs: Set<CLIPModelDownloadID>
}

nonisolated enum CLIPModelDownloadError: Error, LocalizedError, Sendable {
    case serviceNotConfigured
    case releaseBlocked(String)
    case assetPackNotFound(String)
    case downloadedModelNotFound(String)
    case licenceAcceptanceRequired(String)
    case missingVerifiedLicenceText(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:
            "The AI model download service has not been configured."

        case let .releaseBlocked(modelName):
            "\(modelName) is not approved for redistribution yet."

        case let .assetPackNotFound(assetPackID):
            "The model asset pack \(assetPackID) is not present in the download manifest."

        case let .downloadedModelNotFound(path):
            "The downloaded asset pack does not contain the expected model at \(path)."

        case let .licenceAcceptanceRequired(modelName):
            "Accept the verified licence for \(modelName) before downloading it."

        case let .missingVerifiedLicenceText(modelName):
            "A verified complete licence document has not been packaged for \(modelName)."
        }
    }
}

nonisolated protocol CLIPModelDownloadServicing: Sendable {
    func state(
        for descriptor: CLIPModelDownloadDescriptor,
    ) async -> CLIPModelDownloadState

    func download(
        _ descriptor: CLIPModelDownloadDescriptor,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL

    func remove(
        _ descriptor: CLIPModelDownloadDescriptor,
    ) async throws
}

/// Downloads individually checksummed files without loading model weights into memory.
/// A model becomes visible only after every file has been verified and installed.
nonisolated struct GitHubAIModelManifest: Codable, Sendable {
    let schemaVersion: Int
    let models: [Model]

    struct Model: Codable, Sendable {
        let id: CLIPModelDownloadID
        let files: [File]
    }

    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let byteCount: Int64
        let sha256: String

        func validate() throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !path.contains(":"),
                  path != ".rawbrowse-installed.json",
                  byteCount > 0,
                  sha256.count == 64,
                  sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  Self.isAllowedURL(url)
            else { throw GitHubAIModelDownloadError.invalidManifest }
        }

        static func isAllowedURL(_ url: URL) -> Bool {
            guard url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443 else { return false }
            switch url.host {
            case "github.com": return url.path.hasPrefix("/rsyncOSX/AI-models/releases/download/")
            case "raw.githubusercontent.com": return url.path.hasPrefix("/rsyncOSX/AI-models/")
            default: return false
            }
        }
    }

    func model(for id: CLIPModelDownloadID) throws -> Model {
        guard schemaVersion == 1,
              models.filter({ $0.id == id }).count == 1,
              let model = models.first(where: { $0.id == id }),
              !model.files.isEmpty,
              Set(model.files.map(\.path)).count == model.files.count
        else { throw GitHubAIModelDownloadError.invalidManifest }
        for file in model.files {
            try file.validate()
        }
        // A file cannot also be the parent directory of another file.
        let paths = Set(model.files.map(\.path))
        for file in model.files {
            var components = file.path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                guard !paths.contains(components.joined(separator: "/")) else {
                    throw GitHubAIModelDownloadError.invalidManifest
                }
            }
        }
        return model
    }
}

nonisolated enum GitHubAIModelDownloadError: Error, LocalizedError {
    case manifestPending
    case invalidManifest
    case httpStatus(Int)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .manifestPending:
            "AI model downloads are not published yet. Create rsyncOSX/AI-models and publish manifest.json on its main branch."

        case .invalidManifest:
            "The GitHub AI model manifest is invalid or unsupported."

        case let .httpStatus(status):
            "GitHub model download failed (HTTP \(status))."

        case let .checksumMismatch(path):
            "The downloaded model file failed size or SHA-256 verification: \(path)."
        }
    }
}

actor GitHubCLIPModelDownloadService: CLIPModelDownloadServicing {
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/rsyncOSX/AI-models/main/manifest.json")!
    private let root: URL
    private let session: URLSession
    private let manifestURL: URL
    private let isEnabled: Bool

    init(
        root: URL = URL.applicationSupportDirectory.appending(path: "RawBrowse/AI-models", directoryHint: .isDirectory),
        session: URLSession = .shared,
        manifestURL: URL = GitHubCLIPModelDownloadService.manifestURL,
        isEnabled: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
    ) {
        self.root = root
        self.session = session
        self.manifestURL = manifestURL
        self.isEnabled = isEnabled
    }

    func state(for descriptor: CLIPModelDownloadDescriptor) async -> CLIPModelDownloadState {
        let directory = installedDirectory(for: descriptor)
        if FileManager.default.fileExists(atPath: directory.appending(path: ".rawbrowse-installed.json").path) {
            return .installed(location: directory)
        }
        guard isEnabled else { return .notConfigured }
        do {
            _ = try await fetchModel(descriptor.id)
            return .ready
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func download(
        _ descriptor: CLIPModelDownloadDescriptor,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL {
        guard isEnabled else { throw CLIPModelDownloadError.serviceNotConfigured }
        let model = try await fetchModel(descriptor.id)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = model.files.reduce(0.0) { $0 + Double($1.byteCount) }
        var completed = 0.0
        for file in model.files {
            try Task.checkCancellation()
            let delegate = GitHubModelDownloadProgress(completed: completed, total: total, progress: progress)
            let (temporary, response) = try await session.download(from: file.url, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.checkResponse(response, isManifest: false)
            try Task.checkCancellation()
            try Self.verify(temporary, file: file)
            let destination = staging.appending(path: file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += Double(file.byteCount)
            await progress(completed / total)
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(model).write(to: staging.appending(path: ".rawbrowse-installed.json"), options: .atomic)
        let destination = installedDirectory(for: descriptor)
        // Existing models stay usable while files download. Installation is a same-volume rename.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return destination
    }

    func remove(_ descriptor: CLIPModelDownloadDescriptor) throws {
        try Task.checkCancellation()
        let directory = installedDirectory(for: descriptor)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func installedDirectory(for descriptor: CLIPModelDownloadDescriptor) -> URL {
        root.appending(path: descriptor.id.rawValue, directoryHint: .isDirectory)
    }

    private func fetchModel(_ id: CLIPModelDownloadID) async throws -> GitHubAIModelManifest.Model {
        let (data, response) = try await session.data(for: URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData))
        try Self.checkResponse(response)
        return try JSONDecoder().decode(GitHubAIModelManifest.self, from: data).model(for: id)
    }

    private static func checkResponse(_ response: URLResponse, isManifest: Bool = true) throws {
        guard let http = response as? HTTPURLResponse else { throw GitHubAIModelDownloadError.invalidManifest }
        if http.statusCode == 404, isManifest {
            throw GitHubAIModelDownloadError.manifestPending
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw GitHubAIModelDownloadError.httpStatus(http.statusCode)
        }
    }

    static func verify(_ url: URL, file: GitHubAIModelManifest.File) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == file.byteCount, digest == file.sha256 else {
            throw GitHubAIModelDownloadError.checksumMismatch(file.path)
        }
    }
}

/// Immutable delegate fields allow URLSession callbacks to safely report UI progress.
final nonisolated class GitHubModelDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let completed: Double
    let total: Double
    let progress: @MainActor @Sendable (Double) -> Void

    init(completed: Double, total: Double, progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.completed = completed
        self.total = total
        self.progress = progress
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite _: Int64) {
        let value = min(1, (completed + Double(totalBytesWritten)) / total)
        Task { @MainActor [progress] in progress(value) }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}

actor CLIPModelDownloadCoordinator {
    private let catalog: CLIPModelDownloadCatalog
    private let service: any CLIPModelDownloadServicing
    private let acceptanceStore: any RawBrowseAIModelLicenceAcceptanceStoring

    init(
        catalog: CLIPModelDownloadCatalog = .production,
        service: any CLIPModelDownloadServicing = GitHubCLIPModelDownloadService(),
        acceptanceStore: any RawBrowseAIModelLicenceAcceptanceStoring = RawBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: URL.applicationSupportDirectory.appending(path: "RawBrowse/model-licence-acceptances.json"),
        ),
    ) {
        self.catalog = catalog
        self.service = service
        self.acceptanceStore = acceptanceStore
    }

    func snapshot() async -> CLIPModelDownloadsSnapshot {
        var states: [
            CLIPModelDownloadID: CLIPModelDownloadState
        ] = [:]
        var locations: [CLIPModelDownloadID: URL] = [:]
        var acceptedIDs: Set<CLIPModelDownloadID> = []

        for descriptor in catalog.models {
            if case let .blocked(reason) = descriptor.releaseReadiness {
                states[descriptor.id] = .unavailable(reason: reason)
                continue
            }

            let serviceState = await service.state(for: descriptor)
            if let location = serviceState.installedLocation {
                states[descriptor.id] = serviceState
                locations[descriptor.id] = location
                continue
            }

            if descriptor.licence.requiresExplicitAcceptance {
                do {
                    if try await acceptanceStore.acceptance(
                        for: descriptor,
                    ) != nil {
                        acceptedIDs.insert(descriptor.id)
                        states[descriptor.id] = serviceState
                    } else {
                        states[descriptor.id] = .licenceRequired
                    }
                } catch {
                    states[descriptor.id] = .failed(
                        message: error.localizedDescription,
                    )
                }
            } else {
                states[descriptor.id] = serviceState
            }
        }

        return CLIPModelDownloadsSnapshot(
            states: states,
            managedModelLocations: locations,
            acceptedLicenceModelIDs: acceptedIDs,
        )
    }

    func acceptLicence(
        for id: CLIPModelDownloadID,
        rawCullBrowseVersion: String,
    ) async throws {
        let descriptor = try requiredDescriptor(for: id)
        guard descriptor.releaseReadiness.isReady else {
            throw CLIPModelDownloadError.releaseBlocked(
                descriptor.displayName,
            )
        }
        guard descriptor.licence.textSHA256 != nil else {
            throw CLIPModelDownloadError.missingVerifiedLicenceText(
                descriptor.displayName,
            )
        }
        try await acceptanceStore.recordAcceptance(
            for: descriptor,
            rawCullBrowseVersion: rawCullBrowseVersion,
        )
    }

    func download(
        _ id: CLIPModelDownloadID,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> URL {
        let descriptor = try requiredDescriptor(for: id)
        guard descriptor.releaseReadiness.isReady else {
            throw CLIPModelDownloadError.releaseBlocked(
                descriptor.displayName,
            )
        }
        if descriptor.licence.requiresExplicitAcceptance {
            guard try await acceptanceStore.acceptance(
                for: descriptor,
            ) != nil else {
                throw CLIPModelDownloadError.licenceAcceptanceRequired(
                    descriptor.displayName,
                )
            }
        }
        return try await service.download(descriptor, progress: progress)
    }

    func remove(
        _ id: CLIPModelDownloadID,
    ) async throws {
        let descriptor = try requiredDescriptor(for: id)
        try await service.remove(descriptor)
    }

    private func requiredDescriptor(
        for id: CLIPModelDownloadID,
    ) throws -> CLIPModelDownloadDescriptor {
        guard let descriptor = catalog.descriptor(for: id) else {
            throw CLIPModelDownloadError.assetPackNotFound(id.rawValue)
        }
        return descriptor
    }
}
