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
