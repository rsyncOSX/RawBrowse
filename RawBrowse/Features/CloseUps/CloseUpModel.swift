import Foundation
import Observation

@MainActor @Observable
final class CloseUpModel {
    var mode: CloseUpScaleMode = .fitRegion
    private(set) var regions: [URL: CloseUpRegion] = [:]
    @ObservationIgnored private var sourceRevisions: [URL: UUID] = [:]

    func region(for id: URL) -> CloseUpRegion { regions[id] ?? CloseUpRegion() }
    func setRegion(_ region: CloseUpRegion, for id: URL) { regions[id] = region }
    func reset(_ id: URL) { regions[id] = nil }
    func retainFrames(_ frames: [CloseUpFrame]) {
        let ids = Set(frames.map(\.id))
        regions = regions.filter { ids.contains($0.key) }
        for frame in frames {
            if let previous = sourceRevisions[frame.id], previous != frame.revision {
                regions[frame.id] = nil
            }
        }
        sourceRevisions = Dictionary(frames.map { ($0.id, $0.revision) }, uniquingKeysWith: { _, last in last })
    }
}

@MainActor @Observable
final class CloseUpCardModel {
    private(set) var render: CloseUpRender?
    private(set) var failure: String?
    private(set) var isLoading = false
    private var generation = 0

    func load(_ request: CloseUpRequest, using renderer: any CloseUpRendering) async {
        generation += 1
        let current = generation
        render = nil
        failure = nil
        isLoading = true
        do {
            let result = try await renderer.render(request)
            guard !Task.isCancelled, current == generation else { return }
            render = result
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            failure = error.localizedDescription
        }
        if current == generation { isLoading = false }
    }

    func release() {
        generation += 1
        render = nil
        failure = nil
        isLoading = false
    }
}
