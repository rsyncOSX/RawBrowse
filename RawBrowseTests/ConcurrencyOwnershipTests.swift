import Foundation
import os
@testable import RawBrowse
import Testing

@Suite("Concurrency ownership")
@MainActor
struct ConcurrencyOwnershipTests {
    @Test
    func `Replacement prevents a non-cooperative old task from publishing`() async {
        let runner = LatestTaskRunner()
        let started = OwnershipGate()
        let release = OwnershipGate()
        let finished = OwnershipGate()
        let replacementFinished = OwnershipGate()
        var published: [Int] = []
        runner.start { token in
            started.open()
            await release.wait() // Deliberately ignores cancellation.
            if runner.isCurrent(token) {
                published.append(1)
            }
            finished.open()
        }
        await started.wait()
        runner.start { token in
            if runner.isCurrent(token) {
                published.append(2)
            }
            replacementFinished.open()
        }
        await replacementFinished.wait()
        release.open()
        await finished.wait()
        #expect(published == [2])
    }

    @Test
    func `Explicit cancellation invalidates a suspended operation`() async {
        let runner = LatestTaskRunner()
        let started = OwnershipGate()
        let release = OwnershipGate()
        let finished = OwnershipGate()
        var published = false
        runner.start { token in
            started.open()
            await release.wait()
            if runner.isCurrent(token) {
                published = true
            }
            finished.open()
        }
        await started.wait()
        runner.cancel()
        release.open()
        await finished.wait()
        #expect(!published)
    }

    @Test
    func `Worker retains a balanced grant after the session releases it`() async {
        let counts = OSAllocatedUnfairLock(initialState: (starts: 0, stops: 0))
        let url = URL(filePath: "/catalog")
        var session = CatalogAccessLease(
            url: url,
            startAccess: { _ in counts.withLock { $0.starts += 1 }; return true },
            stopAccess: { _ in counts.withLock { $0.stops += 1 } },
        )
        #expect(session != nil)
        let release = OwnershipGate()
        let worker = Task { [lease = session] in
            await release.wait()
            withExtendedLifetime(lease) {}
        }
        session = nil
        #expect(counts.withLock { $0.starts } == 1)
        #expect(counts.withLock { $0.stops } == 0)
        release.open()
        await worker.value
        #expect(counts.withLock { $0.stops } == 1)
    }

    @Test
    func `Failed grant acquisition never calls stop`() {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let lease = CatalogAccessLease(
            url: URL(filePath: "/catalog"),
            startAccess: { _ in false },
            stopAccess: { _ in stops.withLock { $0 += 1 } },
        )
        #expect(lease == nil)
        #expect(stops.withLock { $0 } == 0)
    }
}

/// A latched signal makes task interleavings deterministic without sleeps.
@MainActor
private final class OwnershipGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
