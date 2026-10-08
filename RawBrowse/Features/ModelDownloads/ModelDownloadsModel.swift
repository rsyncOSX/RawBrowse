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
    @ObservationIgnored var locationsChanged: (@MainActor ([CLIPModelDownloadID: URL]) -> Void)?

    init(coordinator: CLIPModelDownloadCoordinator = CLIPModelDownloadCoordinator()) {
        clipModelDownloadCoordinator = coordinator
    }

    func refreshCLIPModels(allowCancelled: Bool = false) async {
        clipModelRefreshGeneration &+= 1
        let generation = clipModelRefreshGeneration
        let snapshot = await clipModelDownloadCoordinator.snapshot()
        guard !Task.isCancelled || allowCancelled, clipModelRefreshGeneration == generation else { return }
        managedCLIPModelLocations = snapshot.managedModelLocations
        clipModelDownloadStates = snapshot.states
        locationsChanged?(managedCLIPModelLocations)
    }

    func acceptModelLicence(_ id: CLIPModelDownloadID) async {
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

    func startCLIPModelDownload(_ id: CLIPModelDownloadID) {
        guard clipModelDownloadTasks[id] == nil,
              clipModelDownloadStates[id]?.canStartDownload == true
        else { return }

        clipModelDownloadStates[id] = .downloading(progress: 0)
        clipModelDownloadTasks[id] = Task { [self] in
            await performCLIPModelDownload(id)
        }
    }

    func cancelCLIPModelDownload(_ id: CLIPModelDownloadID) {
        clipModelDownloadTasks[id]?.cancel()
    }

    func removeManagedCLIPModel(_ id: CLIPModelDownloadID) async {
        guard clipModelDownloadTasks[id] == nil else { return }
        clipModelDownloadStates[id] = .removing
        do {
            try await clipModelDownloadCoordinator.remove(id)
            managedCLIPModelLocations[id] = nil
            await refreshCLIPModels()
        } catch is CancellationError {
            await refreshCLIPModels(allowCancelled: true)
            return
        } catch {
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }

    private func performCLIPModelDownload(_ id: CLIPModelDownloadID) async {
        defer { clipModelDownloadTasks[id] = nil }
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
            await refreshCLIPModels()
        } catch is CancellationError {
            let snapshot = await clipModelDownloadCoordinator.snapshot()
            clipModelDownloadStates[id] = snapshot.states[id] ?? .ready
        } catch {
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }
}
