import Foundation
import Observation

/// A snapshot of the requested export, independent of the current Zoom View.
nonisolated struct RAW9ExportJob: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let adjustments: RAW9Adjustments
    let destination: URL
    let type: String
    var heif10: Bool = false
    var sourceAccessURL: URL?
}

nonisolated struct RAW9ExportFailure: Identifiable, Sendable {
    var id: UUID { job.id }
    let job: RAW9ExportJob
    let message: String
}

/// App-owned FIFO. Only queue bookkeeping runs on the main actor; the renderer
/// performs decoding and file encoding on its own actor.
@Observable @MainActor
final class RAW9ExportQueue {
    static let shared = RAW9ExportQueue()

    private(set) var activeJob: RAW9ExportJob?
    private(set) var waitingCount = 0
    private(set) var failures: [RAW9ExportFailure] = []
    var lastError: String? { failures.last?.message }
    private(set) var isCancellingActiveJob = false
    var queuedJobs: [RAW9ExportJob] { jobs.map(\.job) }
    var outstandingCount: Int {
        waitingCount + (activeJob == nil ? 0 : 1)
    }

    private var jobs: [(job: RAW9ExportJob, scopedURLs: [URL])] = []
    @ObservationIgnored private let startAccess: (URL) -> Bool
    @ObservationIgnored private let stopAccess: (URL) -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<Void, any Error>?
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
        guard activeJob?.id != job.id, !jobs.contains(where: { $0.job.id == job.id }) else { return }
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
                let task = Task {
                    try Task.checkCancellation()
                    try await operation(job)
                    try Task.checkCancellation()
                }
                activeTask = task
                do {
                    try await task.value
                } catch is CancellationError {
                    // The renderer removes staging output before returning.
                } catch {
                    if !task.isCancelled {
                        failures.append(RAW9ExportFailure(job: job,
                            message: "Could not export \(job.destination.lastPathComponent): \(error.localizedDescription)"))
                    }
                }
                activeTask = nil
                activeJob = nil
                isCancellingActiveJob = false
            }
            worker = nil
        }
    }

    func cancelActiveJob() {
        guard activeTask != nil else { return }
        isCancellingActiveJob = true
        activeTask?.cancel()
    }

    func removeQueuedJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.job.id == id }) else { return }
        let entry = jobs.remove(at: index)
        entry.scopedURLs.forEach(stopAccess)
        waitingCount = jobs.count
    }

    func cancelAll() {
        let pending = jobs
        jobs = []
        waitingCount = 0
        for entry in pending { entry.scopedURLs.forEach(stopAccess) }
        cancelActiveJob()
    }

    func dismissFailure(_ id: UUID) {
        failures.removeAll { $0.id == id }
    }

    func retryFailure(_ id: UUID) {
        guard let failure = failures.first(where: { $0.id == id }) else { return }
        dismissFailure(id)
        enqueue(failure.job)
    }

    /// Allows callers to await completion without taking ownership of cancellation.
    func waitUntilFinished() async {
        await worker?.value
    }
}
