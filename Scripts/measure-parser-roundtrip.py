#!/usr/bin/env python3
"""Build a probe against the existing Release object and a temporary instrumented source copy.

Never edits the package checkout or changes the application's decoder concurrency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess


def run(args):
    subprocess.run([str(x) for x in args], check=True)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--products", required=True, type=Path)
parser.add_argument("--package", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--build-only", action="store_true")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
sources = args.output / "InstrumentedSources"
shutil.copytree(args.package / "Sources" / "RawParserKit", sources)
for source in sources.rglob("*.swift"):
    source.chmod(source.stat().st_mode | 0o200)
loader = sources / "RawImageLoader.swift"
text = loader.read_text()
needle = "let cgImage: CGImage? = await limiter.run {"
assert text.count(needle) == 1
text = text.replace(needle, '''let queueStart = ProcessInfo.processInfo.systemUptime
            let cgImage: CGImage? = await limiter.run {
                let workStart = ProcessInfo.processInfo.systemUptime
                defer { ParserExperimentMetrics.record(url, queueStart, workStart) }''')
loader.write_text(text)
(sources / "ParserExperimentMetrics.swift").write_text('''import Foundation
import Synchronization
nonisolated enum ParserExperimentMetrics {
    struct Entry: Sendable {
        let name: String
        let queueStart: Double
        let workStart: Double
        let end: Double
        let isMainThread: Bool
    }
    static let entries = Mutex<[Entry]>([])
    static func record(_ url: URL, _ queueStart: Double, _ workStart: Double) {
        let entry = Entry(name: url.lastPathComponent, queueStart: queueStart,
            workStart: workStart, end: ProcessInfo.processInfo.systemUptime,
            isMainThread: Thread.isMainThread)
        entries.withLock { $0.append(entry) }
    }
    static func snapshot() -> [[String: Any]] {
        entries.withLock { $0.map { ["name": $0.name, "queue_start": $0.queueStart,
            "work_start": $0.workStart, "end": $0.end, "main_thread_at_end": $0.isMainThread] } }
    }
}
''')
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
common = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O", "-g",
          "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
          "-enable-upcoming-feature", "InferIsolatedConformances", "-sdk", sdk,
          "-target", "arm64-apple-macos27.0", "-module-cache-path", args.output / "ModuleCache"]
harness = Path(__file__).with_name("ParserRoundTripProbe.swift")
run(common + ["-I", args.products, harness, args.products / "RawParserKit.o",
              "-o", args.output / "production-probe"])
run(common + ["-D", "PARSER_METRICS", "-module-name", "RawParserProbe", harness,
              *sorted(sources.rglob("*.swift")), "-o", args.output / "instrumented-probe"])
run(["xcrun", "dsymutil", args.output / "production-probe"])
run(["xcrun", "dsymutil", args.output / "instrumented-probe"])
identity = {"package_revision": subprocess.check_output(
    ["git", "-C", str(args.package), "rev-parse", "HEAD"], text=True).strip(),
    "production_object_sha256": hashlib.sha256((args.products / "RawParserKit.o").read_bytes()).hexdigest(),
    "harness_sha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
    "source_hashes": {str(p.relative_to(sources)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(sources.rglob("*.swift"))}}
(args.output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
if args.build_only:
    raise SystemExit(0)
workloads = [("large", "/Volumes/MacMini4/Lundfug_7juli_2026/DCIM_A7R6/100MSDCF", 56),
             ("small", "/Volumes/MacMini4/Pictures_raw/2026/06_mai_2026", 26)]
trials = []
checksums = {}
for trial in range(1, 4):
    for label, folder, count in workloads:
        for concurrency in ([1, 6, 56] if trial % 2 else [56, 6, 1]):
            for variant in (["production", "instrumented"] if trial % 2 else ["instrumented", "production"]):
                dest = args.output / f"{label}-{variant}-c{concurrency}-t{trial}.json"
                run([args.output / f"{variant}-probe", folder, count, concurrency, 200, dest])
                data = json.loads(dest.read_text())
                data.update(workload=label, variant=variant, trial=trial)
                for image in data["images"]:
                    key = label, image["name"]
                    signature = image["width"], image["height"], image["checksum"]
                    if key in checksums and checksums[key] != signature:
                        raise ValueError(f"Pixel output mismatch: {key}: {dest}")
                    checksums[key] = signature
                data["median_request_ms"] = statistics.median((x["end"] - x["start"]) * 1000 for x in data["images"])
                if "intervals" in data:
                    intervals = data["intervals"]
                    assert len(intervals) == count
                    data["median_slot_wait_ms"] = statistics.median((x["work_start"] - x["queue_start"]) * 1000 for x in intervals)
                    data["median_work_ms"] = statistics.median((x["end"] - x["work_start"]) * 1000 for x in intervals)
                trials.append(data)
                print(label, variant, trial, concurrency, round(data["batch_ms"], 2), flush=True)
(args.output / "results.json").write_text(json.dumps({"identity": identity,
    "pixel_checksums_match": True, "trials": trials}, indent=2) + "\n")
