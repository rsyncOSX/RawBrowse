import Foundation
import Observation

@Observable @MainActor
final class ModelDownloadsModel {
    private(set) var clipModelDownloadStates: [CLIPModelDownloadID: CLIPModelDownloadState] =
        Dictionary(uniqueKeysWithValues: CLIPModelDownloadID.allCases.map { ($0, .checking) })
    private(set) var managedCLIPModelLocations: [CLIPModelDownloadID: URL] = [:]
    @ObservationIgnored private let clipModelDownloadCoordinator: CLIPModelDownloadCoordinator
    @ObservationIgnored private var clipModelDownloadTasks: [CLIPModelDownloadID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clipModelRefreshGeneration = 0
    @ObservationIgnored var prepareForRemoval: (@MainActor (CLIPModelDownloadID) async -> Void)?
    private var isShuttingDown = false
    @ObservationIgnored private var removingModels: Set<CLIPModelDownloadID> = []
    @ObservationIgnored var locationsChanged: (@MainActor ([CLIPModelDownloadID: URL]) -> Void)?

    init(coordinator: CLIPModelDownloadCoordinator = CLIPModelDownloadCoordinator()) {
        clipModelDownloadCoordinator = coordinator
    }

    func refreshCLIPModels(allowCancelled: Bool = false, finishingDownload: CLIPModelDownloadID? = nil) async {
        guard !isShuttingDown, removingModels.isEmpty else { return }
        clipModelRefreshGeneration &+= 1
        let generation = clipModelRefreshGeneration
        let snapshot = await clipModelDownloadCoordinator.snapshot()
        guard !Task.isCancelled || allowCancelled, clipModelRefreshGeneration == generation, !isShuttingDown, removingModels.isEmpty else { return }
        managedCLIPModelLocations = snapshot.managedModelLocations
        var states = snapshot.states
        for id in clipModelDownloadTasks.keys where id != finishingDownload {
            switch clipModelDownloadStates[id] {
            case .downloading, .validating:
                states[id] = clipModelDownloadStates[id]
            default:
                break
            }
        }
        clipModelDownloadStates = states
        locationsChanged?(managedCLIPModelLocations)
    }

    func acceptModelLicence(_ id: CLIPModelDownloadID) async {
        guard !isShuttingDown else { return }
        do {
            try await clipModelDownloadCoordinator.acceptLicence(
                for: id,
                rawCullBrowseVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            )
            await refreshCLIPModels()
        } catch {
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }

    @discardableResult
    func startCLIPModelDownload(_ id: CLIPModelDownloadID) -> Task<Void, Never>? {
        guard !isShuttingDown, clipModelDownloadTasks[id] == nil,
              clipModelDownloadStates[id]?.canStartDownload == true
        else { return nil }

        return beginDownload(id) { [self] in await performCLIPModelDownload(id) }
    }

    @discardableResult
    func beginDownload(_ id: CLIPModelDownloadID,
                       operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isShuttingDown, clipModelDownloadTasks[id] == nil else { return nil }
        clipModelDownloadStates[id] = .downloading(progress: 0)
        let task = Task { [self] in
            defer { clipModelDownloadTasks[id] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        clipModelDownloadTasks[id] = task
        return task
    }

    func cancelCLIPModelDownload(_ id: CLIPModelDownloadID) {
        clipModelDownloadTasks[id]?.cancel()
    }

    func removeManagedCLIPModel(_ id: CLIPModelDownloadID) async {
        guard !isShuttingDown, clipModelDownloadTasks[id] == nil, removingModels.insert(id).inserted else { return }
        clipModelRefreshGeneration &+= 1
        clipModelDownloadStates[id] = .removing
        await prepareForRemoval?(id)
        do {
            try Task.checkCancellation()
            try await clipModelDownloadCoordinator.remove(id)
            managedCLIPModelLocations[id] = nil
            removingModels.remove(id)
            await refreshCLIPModels()
        } catch is CancellationError {
            removingModels.remove(id)
            await refreshCLIPModels(allowCancelled: true)
            return
        } catch {
            removingModels.remove(id)
            await refreshCLIPModels(allowCancelled: true)
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }

    func cancelAndWait() async {
        isShuttingDown = true
        clipModelRefreshGeneration &+= 1
        let pending = Array(clipModelDownloadTasks.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }

    func resumeAfterCancelledTermination() async {
        isShuttingDown = false
        await refreshCLIPModels()
    }

    private func performCLIPModelDownload(_ id: CLIPModelDownloadID) async {
        do {
            let location = try await clipModelDownloadCoordinator.download(
                id,
                progress: { [weak self] progress in
                    guard let self, !Task.isCancelled,
                          case .downloading = clipModelDownloadStates[id],
                          clipModelDownloadTasks[id]?.isCancelled == false else { return }
                    clipModelDownloadStates[id] = .downloading(
                        progress: min(max(progress, 0), 1),
                    )
                },
            )
            try Task.checkCancellation()
            clipModelDownloadStates[id] = .validating
            managedCLIPModelLocations[id] = location
            await refreshCLIPModels(finishingDownload: id)
        } catch is CancellationError {
            await refreshCLIPModels(allowCancelled: true, finishingDownload: id)
        } catch {
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }
}
