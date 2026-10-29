#!/usr/bin/env python3
"""Summarize verified app model delivery; never labels it painted-frame latency."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("root", type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
manifest = json.loads((Path(__file__).resolve().parents[1] / "Docs/Performance/Phase4-Workloads.json").read_text())
trials = []
configurations = []
for log in sorted((args.root / "RunsFinal").glob("*.jsonl")):
    metadata = json.loads(log.with_suffix(".launch.json").read_text())
    records = []
    for line in log.read_text().splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    config = dict(metadata["configuration"])
    config.pop("executable")
    configurations.append(config)
    trial = {"variant": metadata["variant"], "state": metadata["state"], "trial": metadata["trial"],
             "log": str(log.resolve()), "sha256": hashlib.sha256(log.read_bytes()).hexdigest(), "workloads": {}}
    pending = set()
    for record in records:
        event = record.get("event", "")
        if event.endswith(".taskStarted"):
            pending.add(record["fields"]["task_id"])
        elif event.endswith(".taskFinished"):
            pending.discard(record["fields"]["task_id"])
    trial["pending_image_tasks_at_log_end"] = len(pending)
    trial["peak_owned_thumbnail_tasks"] = max((r["fields"]["active_thumbnail_tasks"] for r in records
        if r.get("event") == "thumbnail.taskStarted"), default=0)
    trial["shared_waits"] = sum(r.get("event") == "thumbnail.sharedWait" for r in records)
    trial["rejected_thumbnail_deliveries"] = dict(collections.Counter(r["result"] for r in records
        if r.get("stage") == "thumbnail.presentationDelivery" and r["result"] != "image"))
    for workload in manifest["workloads"]:
        folder = Path(workload["path"]).name
        count = 56 if folder == "100MSDCF" else 26
        names = sorted(f["name"] for f in workload["files"] if f["name"].lower().endswith(".arw"))[:count]
        intervals = [r for r in records if "stage" in r and f"/{folder}/" in r["path"] and Path(r["path"]).name in names]
        stages = {}
        first_deliveries = []
        for stage in sorted({r["stage"] for r in intervals}):
            first = {}
            for record in sorted(intervals, key=lambda r: r["start"]):
                if record["stage"] == stage:
                    first.setdefault(record["path"], record)
            values = list(first.values())
            stages[stage] = {"count": len(values), "median_ms": statistics.median(r["duration_ms"] for r in values),
                             "results": dict(collections.Counter(r["result"] for r in values))}
            if stage == "thumbnail.presentationDelivery":
                first_deliveries = values
        if len(first_deliveries) != count or any(r["result"] != "image" for r in first_deliveries):
            raise ValueError(f"Initial cohort incomplete or rejected: {log}: {folder}")
        start = min(r["start"] for r in first_deliveries)
        folder_stages = {}
        for record in sorted(records, key=lambda r: r.get("start", 0)):
            if record.get("path") == workload["path"] and "stage" in record:
                folder_stages.setdefault(record["stage"], record["duration_ms"])
        trial["workloads"][folder] = {"stages": stages, "folder_stages_ms": folder_stages,
            "first_model_delivery_ms": (min(r["end"] for r in first_deliveries) - start) * 1000,
            "cohort_model_delivery_window_ms": (max(r["end"] for r in first_deliveries) - start) * 1000}
    trials.append(trial)
if any(c != configurations[0] for c in configurations):
    raise ValueError("Mismatched app configurations")
identity = {}
for variant in ["Baseline", "Candidate"]:
    product = args.root / (variant + "Build/Build/Products/Release")
    binary = product / "RawBrowse.app/Contents/MacOS/RawBrowse"
    identity[variant] = {"executable": str(binary.resolve()),
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "binary_uuid": subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(binary)], text=True).strip(),
        "dsym_uuid": subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(product / "RawBrowse.app.dSYM")], text=True).strip()}
output = {"scope": "Initial accepted model image delivery, not painted frames",
          "configuration": configurations[0], "build_identity": identity,
          "source_identity": json.loads((args.root / "identity.json").read_text()), "trials": trials}
args.output.write_text(json.dumps(output, indent=2) + "\n")
