import Foundation
import Observation

/// A snapshot of the requested export, independent of the current Zoom View.
nonisolated struct RAW9ExportJob: Sendable {
    let source: URL
    let adjustments: RAW9Adjustments
    let destination: URL
    let type: String
    var heif10: Bool = false
    var sourceAccessURL: URL?
}

/// App-owned FIFO. Only queue bookkeeping runs on the main actor; the renderer
/// performs decoding and file encoding on its own actor.
@Observable @MainActor
final class RAW9ExportQueue {
    static let shared = RAW9ExportQueue()

    private(set) var activeJob: RAW9ExportJob?
    private(set) var waitingCount = 0
    var lastError: String?
    var outstandingCount: Int {
        waitingCount + (activeJob == nil ? 0 : 1)
    }

    @ObservationIgnored private var jobs: [(job: RAW9ExportJob, scopedURLs: [URL])] = []
    @ObservationIgnored private let startAccess: (URL) -> Bool
    @ObservationIgnored private let stopAccess: (URL) -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let operation: @Sendable (RAW9ExportJob) async throws -> Void

    init(
        operation: @escaping @Sendable (RAW9ExportJob) async throws -> Void = { job in
            try await performExport(job)
        },
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
    ) {
        self.operation = operation
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    /// Explicitly leave the main actor even if Swift optimizes access to a newly
    /// created renderer whose isolation region has not escaped yet.
    @concurrent private nonisolated static func performExport(_ job: RAW9ExportJob) async throws {
        let renderer = RAW9PreviewRenderer()
        try await renderer.export(
            url: job.source, adjustments: job.adjustments, destination: job.destination,
            type: job.type, heif10: job.heif10,
        )
    }

    func enqueue(_ job: RAW9ExportJob) {
        // Acquire while the caller's catalog grant is still active, including
        // time spent waiting in the FIFO. Keep the original scoped URLs.
        let scopedURLs = [job.sourceAccessURL ?? job.source, job.destination].filter { startAccess($0) }
        // A false return can mean a URL already accessible through the sandbox
        // or save panel; only successful starts require a matching stop.
        jobs.append((job, scopedURLs))
        waitingCount = jobs.count
        guard worker == nil else { return }
        // This unstructured worker belongs to the queue, never to a view's .task.
        // Retain the queue until all accepted jobs finish, even if its UI disappears.
        worker = Task(priority: .utility) {
            while !jobs.isEmpty {
                let entry = jobs.removeFirst()
                let job = entry.job
                defer { entry.scopedURLs.forEach(stopAccess) }
                waitingCount = jobs.count
                activeJob = job
                do {
                    try await operation(job)
                } catch {
                    lastError = "Could not export \(job.destination.lastPathComponent): \(error.localizedDescription)"
                }
                activeJob = nil
            }
            worker = nil
        }
    }

    /// Allows callers to await completion without taking ownership of cancellation.
    func waitUntilFinished() async {
        await worker?.value
    }
}
