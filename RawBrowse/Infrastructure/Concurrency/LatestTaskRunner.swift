import Foundation

/// Owns one replaceable UI operation. Cancellation alone cannot prevent a
/// non-cooperative operation from publishing, so callers also check the token.
@MainActor
final class LatestTaskRunner {
    private var token = UUID()
    private var task: Task<Void, Never>?

    func isCurrent(_ candidate: UUID) -> Bool {
        token == candidate
    }

    func cancel() {
        token = UUID()
        task?.cancel()
        task = nil
    }

    @discardableResult
    func start(_ operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never> {
        cancel()
        let current = token
        let operationTask = Task {
            defer {
                if isCurrent(current) {
                    task = nil
                }
            }
            guard !Task.isCancelled else { return }
            await operation(current)
        }
        task = operationTask
        return operationTask
    }
}
