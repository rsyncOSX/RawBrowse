import Foundation
@testable import RawBrowse
import Testing

struct AIModelDownloadTests {
    @Test(arguments: CLIPModelDownloadCatalog.production.models)
    func `bundled licence matches verified hash`(_ descriptor: CLIPModelDownloadDescriptor) {
        #expect(descriptor.licence.verifiedBundledText(in: .main) != nil)
    }

    @Test
    func `sam download requires recorded licence acceptance`() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RawBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: directory.appending(path: "acceptances.json"),
        )
        let coordinator = CLIPModelDownloadCoordinator(
            service: ReadyModelDownloadService(), acceptanceStore: store,
        )
        let before = await coordinator.snapshot()
        #expect(before.states[.sam3] == .licenceRequired)
        await #expect(throws: CLIPModelDownloadError.self) {
            try await coordinator.download(.sam3) { _ in }
        }
        try await coordinator.acceptLicence(for: .sam3, rawCullBrowseVersion: "test")
        let after = await coordinator.snapshot()
        #expect(after.states[.sam3] == .ready)
        let descriptor = try #require(CLIPModelDownloadCatalog.production.descriptor(for: .sam3))
        let persisted = RawBrowseAIModelLicenceAcceptanceFileStore(
            fileURL: directory.appending(path: "acceptances.json"),
        )
        let acceptance = try await persisted.acceptance(for: descriptor)
        #expect(acceptance?.matches(descriptor: descriptor) == true)
    }

    @Test @MainActor
    func `Late download cancellation reconciles installation and preserves other progress`() async throws {
        let service = LateInstallService()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelDownloadsModel(coordinator: CLIPModelDownloadCoordinator(
            service: service,
            acceptanceStore: RawBrowseAIModelLicenceAcceptanceFileStore(fileURL: directory.appending(path: "licences.json")),
        ))
        await model.refreshCLIPModels()
        var activated: [CLIPModelDownloadID: URL] = [:]
        model.locationsChanged = { activated = $0 }
        let task = try #require(model.startCLIPModelDownload(.clipDataComp))
        await service.waitForStart()
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.5))
        await model.refreshCLIPModels()
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.5))
        model.cancelCLIPModelDownload(.clipDataComp)
        await service.pauseNextInstalledSnapshot()
        await service.finishInstallation()
        await service.waitForPausedSnapshot()
        // A competing refresh wins while the finishing worker still owns its task.
        await model.refreshCLIPModels()
        let location = URL(filePath: "/tmp/test-installed-model")
        #expect(model.clipModelDownloadStates[.clipDataComp] == .installed(location: location))
        await service.releaseSnapshot()
        await task.value
        #expect(model.clipModelDownloadStates[.clipDataComp] == .installed(location: location))
        #expect(model.managedCLIPModelLocations[.clipDataComp] == location)
        #expect(activated[.clipDataComp] == location)
    }

    @Test @MainActor
    func `Cancelling a download before its worker starts restores a startable state`() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelDownloadsModel(coordinator: CLIPModelDownloadCoordinator(
            service: ReadyModelDownloadService(),
            acceptanceStore: RawBrowseAIModelLicenceAcceptanceFileStore(fileURL: directory.appending(path: "licences.json")),
        ))
        await model.refreshCLIPModels()
        let task = try #require(model.startCLIPModelDownload(.clipDataComp))
        model.cancelCLIPModelDownload(.clipDataComp)
        await task.value
        #expect(model.clipModelDownloadStates[.clipDataComp] == .ready)
        #expect(model.managedCLIPModelLocations[.clipDataComp] == nil)
    }

    @Test(arguments: ["success", "failure", "cancel", "shutdown"]) @MainActor
    func `Old progress cannot mutate terminal state or a replacement attempt`(_ outcome: String) async throws {
        let service = HeldProgressService()
        let model = ModelDownloadsModel(coordinator: CLIPModelDownloadCoordinator(service: service))
        await model.refreshCLIPModels()
        let first = try #require(model.startCLIPModelDownload(.clipDataComp))
        let oldProgress = try await service.nextProgress()
        oldProgress(0.6)
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.6))
        oldProgress(0.2)
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.6))

        var shutdown: Task<Void, Never>?
        if outcome == "cancel" {
            model.cancelCLIPModelDownload(.clipDataComp)
            oldProgress(0.9)
            #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.6))
        } else if outcome == "shutdown" {
            shutdown = Task { await model.cancelAndWait() }
            // Wait for shutdown to cancel the owned worker without timing sleeps.
            await service.waitForCancellation()
            oldProgress(0.9)
            #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.6))
        }
        await service.finish(failing: outcome == "failure")
        await first.value
        await shutdown?.value
        let terminal = model.clipModelDownloadStates[.clipDataComp]
        oldProgress(0.95)
        #expect(model.clipModelDownloadStates[.clipDataComp] == terminal)
        if outcome == "shutdown" { await model.resumeAfterCancelledTermination() }
        // Simulate removing the installed fixture before retrying a successful attempt.
        await service.resetInstallation()
        await model.refreshCLIPModels()
        let second = try #require(model.startCLIPModelDownload(.clipDataComp))
        let newProgress = try await service.nextProgress()
        newProgress(0.3)
        oldProgress(0.99)
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.3))
        newProgress(0.4)
        #expect(model.clipModelDownloadStates[.clipDataComp] == .downloading(progress: 0.4))
        await service.finish(failing: false)
        await second.value
    }

    @Test @MainActor
    func `Removal waits for runtime preparation and rejects duplicate removal`() async {
        let service = ObservedRemovalService()
        let model = ModelDownloadsModel(coordinator: CLIPModelDownloadCoordinator(service: service))
        var release: CheckedContinuation<Void, Never>?
        let entered = AsyncStream<Void>.makeStream()
        model.prepareForRemoval = { _ in
            entered.continuation.yield(())
            await withCheckedContinuation { release = $0 }
        }
        let removal = Task { await model.removeManagedCLIPModel(.clipDataComp) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await service.removalCount == 0)
        await model.removeManagedCLIPModel(.clipDataComp)
        #expect(await service.removalCount == 0)
        release?.resume()
        await removal.value
        #expect(await service.removalCount == 1)
        entered.continuation.finish()
    }

    @Test @MainActor
    func `cancelled removal refreshes state`() async {
        let coordinator = CLIPModelDownloadCoordinator(service: CancelledRemovalService())
        let model = ModelDownloadsModel(coordinator: coordinator)
        let removal = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.removeManagedCLIPModel(.clipDataComp)
        }
        await removal.value
        #expect(model.clipModelDownloadStates[.clipDataComp] != .removing)
    }
}

private actor ReadyModelDownloadService: CLIPModelDownloadServicing {
    func state(for _: CLIPModelDownloadDescriptor) -> CLIPModelDownloadState {
        .ready
    }

    func download(
        _: CLIPModelDownloadDescriptor,
        progress _: @escaping @MainActor @Sendable (Double) -> Void,
    ) -> URL {
        URL(filePath: "/tmp/model")
    }

    func remove(_: CLIPModelDownloadDescriptor) {}
}

private actor CancelledRemovalService: CLIPModelDownloadServicing {
    func state(for _: CLIPModelDownloadDescriptor) -> CLIPModelDownloadState {
        .ready
    }

    func download(_: CLIPModelDownloadDescriptor, progress _: @escaping @MainActor @Sendable (Double) -> Void) -> URL {
        URL(filePath: "/tmp/model")
    }

    func remove(_: CLIPModelDownloadDescriptor) throws {
        throw CancellationError()
    }
}

private actor ObservedRemovalService: CLIPModelDownloadServicing {
    var removalCount = 0
    func state(for _: CLIPModelDownloadDescriptor) -> CLIPModelDownloadState {
        .ready
    }

    func download(_: CLIPModelDownloadDescriptor, progress _: @escaping @MainActor @Sendable (Double) -> Void) -> URL {
        URL(filePath: "/tmp/model")
    }

    func remove(_: CLIPModelDownloadDescriptor) {
        removalCount += 1
    }
}

private actor LateInstallService: CLIPModelDownloadServicing {
    private var installed = false
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var shouldPauseSnapshot = false
    private var pausedSnapshot: CheckedContinuation<Void, Never>?
    private var snapshotWaiter: CheckedContinuation<Void, Never>?

    func state(for descriptor: CLIPModelDownloadDescriptor) async -> CLIPModelDownloadState {
        guard installed, descriptor.id == .clipDataComp else { return .ready }
        if shouldPauseSnapshot {
            shouldPauseSnapshot = false
            await withCheckedContinuation {
                pausedSnapshot = $0
                snapshotWaiter?.resume()
                snapshotWaiter = nil
            }
        }
        return .installed(location: URL(filePath: "/tmp/test-installed-model"))
    }

    func pauseNextInstalledSnapshot() { shouldPauseSnapshot = true }

    func waitForPausedSnapshot() async {
        if pausedSnapshot == nil { await withCheckedContinuation { snapshotWaiter = $0 } }
    }

    func releaseSnapshot() {
        pausedSnapshot?.resume()
        pausedSnapshot = nil
    }

    func download(_: CLIPModelDownloadDescriptor,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async -> URL {
        await progress(0.5)
        await withCheckedContinuation {
            release = $0
            started?.resume()
            started = nil
        }
        installed = true
        return URL(filePath: "/tmp/test-installed-model")
    }

    func waitForStart() async {
        if release == nil { await withCheckedContinuation { started = $0 } }
    }

    func finishInstallation() {
        release?.resume()
        release = nil
    }

    func remove(_: CLIPModelDownloadDescriptor) {}
}

/// Retains the real model's progress closure beyond worker exit to control stale delivery.
private actor HeldProgressService: CLIPModelDownloadServicing {
    private let events = AsyncStream<@MainActor @Sendable (Double) -> Void>.makeStream()
    private let cancellationEvents = AsyncStream<Void>.makeStream()
    private var release: CheckedContinuation<Void, Never>?
    private var failing = false
    private var installed = false

    func state(for _: CLIPModelDownloadDescriptor) -> CLIPModelDownloadState {
        installed ? .installed(location: URL(filePath: "/tmp/held-progress-model")) : .ready
    }
    func resetInstallation() { installed = false }
    func remove(_: CLIPModelDownloadDescriptor) {}

    func nextProgress() async throws -> @MainActor @Sendable (Double) -> Void {
        var iterator = events.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func waitForCancellation() async {
        var iterator = cancellationEvents.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func download(_: CLIPModelDownloadDescriptor,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                release = $0
                events.continuation.yield(progress)
            }
        } onCancel: {
            self.cancellationEvents.continuation.yield(())
        }
        try Task.checkCancellation()
        if failing { throw URLError(.cannotLoadFromNetwork) }
        installed = true
        return URL(filePath: "/tmp/held-progress-model")
    }

    func finish(failing: Bool) {
        self.failing = failing
        release?.resume()
        release = nil
    }
}
