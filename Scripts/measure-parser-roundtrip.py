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


def run(args, timeout=180, cwd=None):
    subprocess.run([str(x) for x in args], check=True, timeout=timeout, cwd=cwd)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--products", required=True, type=Path)
parser.add_argument("--package", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--build-only", action="store_true")
parser.add_argument("--candidate", action="store_true", help="Also test a temporary concurrent-executor decode helper")
args = parser.parse_args()
args.products = args.products.resolve()
args.package = args.package.resolve()
args.output = args.output.resolve()
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
harness = Path(__file__).with_name("ParserRoundTripProbe.swift").resolve()
def compile_probe(variant, inputs):
    objects = args.output / (variant + "-objects")
    objects.mkdir()
    run(common + ["-save-temps", *inputs, "-o", args.output / (variant + "-probe")], cwd=objects)
compile_probe("production", ["-I", args.products, harness, args.products / "RawParserKit.o"])
compile_probe("instrumented", ["-D", "PARSER_METRICS", "-module-name", "RawParserProbe", harness,
                              *sorted(sources.rglob("*.swift"))])
variants = ["production", "instrumented"]
if args.candidate:
    candidate = args.output / "CandidateSources"
    shutil.copytree(sources, candidate)
    candidate_loader = candidate / "RawImageLoader.swift"
    candidate_text = candidate_loader.read_text()
    begin = candidate_text.index("let cgImage: CGImage? = await limiter.run {")
    body_start = begin + len("let cgImage: CGImage? = await limiter.run {")
    body_end = candidate_text.index("            }\n            \n            guard let cgImage", body_start)
    body = candidate_text[body_start:body_end]
    replacement = '''let cgImage: CGImage? = await limiter.run {
                await Self.decodeProbeThumbnail(for: url, boundedTargetSize: boundedTargetSize,
                    useRAW9: useRAW9, queueStart: queueStart)
'''
    candidate_text = candidate_text[:begin] + replacement + candidate_text[body_end:]
    marker = "    public func thumbnailCGImage("
    helper = '''    @concurrent private static func decodeProbeThumbnail(
        for url: URL, boundedTargetSize: Int, useRAW9: Bool, queueStart: Double
    ) async -> CGImage? {''' + body + "    }\n\n"
    assert candidate_text.count(marker) == 1
    candidate_text = candidate_text.replace(marker, helper + marker)
    candidate_loader.write_text(candidate_text)
    compile_probe("candidate", ["-D", "PARSER_METRICS", "-module-name", "RawParserCandidate", harness,
                                *sorted(candidate.rglob("*.swift"))])
    run(["xcrun", "dsymutil", args.output / "candidate-probe"])
    variants.append("candidate")
run(["xcrun", "dsymutil", args.output / "production-probe"])
run(["xcrun", "dsymutil", args.output / "instrumented-probe"])
identity = {"package_revision": subprocess.check_output(
    ["git", "-C", str(args.package), "rev-parse", "HEAD"], text=True).strip(),
    "production_object_sha256": hashlib.sha256((args.products / "RawParserKit.o").read_bytes()).hexdigest(),
    "harness_sha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
    "source_hashes": {str(p.relative_to(sources)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(sources.rglob("*.swift"))}}
if args.candidate:
    identity["candidate_loader_sha256"] = hashlib.sha256(candidate_loader.read_bytes()).hexdigest()
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
            for variant in (variants if trial % 2 else list(reversed(variants))):
                dest = args.output / f"{label}-{variant}-c{concurrency}-t{trial}.json"
                run([args.output / f"{variant}-probe", folder, count, concurrency, 200, dest], timeout=30)
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
summary_trials = []
for trial in trials:
    item = {key: value for key, value in trial.items() if key not in {"images", "intervals"}}
    if "intervals" in trial:
        active = peak = 0
        events = sorted([(x["work_start"], 1) for x in trial["intervals"]]
                        + [(x["end"], -1) for x in trial["intervals"]])
        for _, delta in events:
            active += delta
            peak = max(peak, active)
        item["peak_work_overlap"] = peak
        item["main_thread_at_work_end_count"] = sum(x["main_thread_at_end"] for x in trial["intervals"])
    summary_trials.append(item)
summary = {"identity": identity, "pixel_checksums_match": True, "trials": summary_trials,
    "outputs": [{"workload": key[0], "name": key[1], "width": value[0], "height": value[1],
                 "rgba_sha256": value[2]} for key, value in sorted(checksums.items())],
    "raw_results_path": str(args.output / "results.json"),
    "raw_results_sha256": hashlib.sha256((args.output / "results.json").read_bytes()).hexdigest()}
(args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
