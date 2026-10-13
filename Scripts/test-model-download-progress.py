#!/usr/bin/env python3
"""Run the production download bridge against a slow loopback HTTP server.

Run: python3 Scripts/test-model-download-progress.py
This runs outside the sandboxed app test host, which cannot listen on TCP ports.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class ModelHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(1_048_576))
        self.end_headers()
        try:
            for _ in range(64):
                self.wfile.write(b"x" * 16_384)
                self.wfile.flush()
                time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the cancellation check disconnects.

    def log_message(self, *args):
        pass


source = (Path(__file__).resolve().parents[1] / "RawBrowse/Features/ModelDownloads/CLIPManagedModels.swift").read_text()
# Compile the production delegate itself, without the app's unrelated dependencies.
delegate = source.split("final nonisolated class GitHubModelDownloadProgress", 1)[1].split("\nactor CLIPModelDownloadCoordinator", 1)[0]
delegate = "final nonisolated class GitHubModelDownloadProgress" + delegate
probe = r'''
@main struct Check {
    @MainActor static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        var values: [Double] = []
        let delegate = GitHubModelDownloadProgress(completed: 0, total: 1_048_576) {
            values.append($0)
        }
        let (file, response) = try await delegate.download(from: url, session: .shared)
        defer { try? FileManager.default.removeItem(at: file) }
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(values.contains { $0 > 0 && $0 < 1 }, "Missing intermediate progress")
        let bytes = try Data(contentsOf: file)
        precondition(bytes == Data(repeating: 120, count: 1_048_576), "Downloaded file was not preserved")
        print("PASS: \(values.count) progress callbacks and complete downloaded file")

        let updates = AsyncStream<Double>.makeStream()
        defer { updates.continuation.finish() }
        let cancellable = GitHubModelDownloadProgress(completed: 0, total: 1_048_576) {
            updates.continuation.yield($0)
        }
        let download = Task { try await cancellable.download(from: url, session: .shared) }
        var iterator = updates.stream.makeAsyncIterator()
        _ = await iterator.next()
        download.cancel()
        do {
            let (unexpected, _) = try await download.value
            try? FileManager.default.removeItem(at: unexpected)
            fatalError("Expected CancellationError")
        } catch is CancellationError {
            print("PASS: cancellation after receiving download progress")
        }
    }
}
'''

with ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler) as server, tempfile.TemporaryDirectory(prefix="rawbrowse-progress-") as workdir:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        work = Path(workdir)
        swift = work / "ProgressCheck.swift"
        binary = work / "ProgressCheck"
        swift.write_text("import Foundation\nimport Synchronization\n" + delegate + probe)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(work / "ModuleCache"), str(swift), "-o", str(binary)], check=True, timeout=120)
        subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}/model"], check=True, timeout=30)
    finally:
        server.shutdown()
