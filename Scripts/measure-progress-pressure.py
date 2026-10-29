#!/usr/bin/env python3
"""Measure the production delegate's MainActor fan-out, without network or app UI.

Usage: python3 Scripts/measure-progress-pressure.py > results.json
Requires Xcode Swift 6. Input bursts deliberately hold MainActor until all delegate
callbacks are submitted; this is a stress ceiling, not a real transfer cadence.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'RawBrowse/Features/ModelDownloads/CLIPManagedModels.swift').read_text()
delegate = 'final nonisolated class GitHubModelDownloadProgress' + source.split('final nonisolated class GitHubModelDownloadProgress', 1)[1].split('\nactor CLIPModelDownloadCoordinator', 1)[0]
probe = r'''
@main struct Probe {
    @MainActor static func main() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/fixture")!)
        for count in [100, 1000, 10000] {
            for trial in 1...3 {
                var received = 0
                var last = 0.0
                var regressions = 0
                let gate = AsyncStream<Void>.makeStream()
                let start = ContinuousClock.now
                let delegate = GitHubModelDownloadProgress(completed: 0, total: Double(count)) { value in
                    if value < last { regressions += 1 }
                    last = value
                    received += 1
                    if received == count { gate.continuation.yield(()); gate.continuation.finish() }
                }
                for index in 1...count {
                    delegate.urlSession(session, downloadTask: task, didWriteData: 1,
                                        totalBytesWritten: Int64(index), totalBytesExpectedToWrite: Int64(count))
                }
                for await _ in gate.stream { break }
                let elapsed = start.duration(to: .now).components
                let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                print("{\"callbacks\":\(count),\"deliveries\":\(received),\"trial\":\(trial),\"drain_ms\":\(ms),\"regressions\":\(regressions),\"last\":\(last)}")
            }
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='rawbrowse-pressure-') as directory:
    work = Path(directory)
    swift = work / 'Probe.swift'
    binary = work / 'Probe'
    swift.write_text('import Foundation\nimport Synchronization\n' + delegate + probe)
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(work / 'ModuleCache'), str(swift), '-o', str(binary)], check=True, timeout=120)
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
    print(json.dumps({'delegate_sha256': hashlib.sha256(delegate.encode()).hexdigest(), 'optimization': '-O', 'trials': [json.loads(line) for line in result.stdout.splitlines()]}, indent=2))
