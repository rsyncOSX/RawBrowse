#!/usr/bin/env python3
"""Summarize opt-in stage logs; timings are requests, not painted frames."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics


def summarize(path):
    records = []
    for line in path.read_text().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue  # /usr/bin/time and framework diagnostics may share stderr.
        if isinstance(record, dict) and "stage" in record:
            records.append(record)
    ids = [r["id"] for r in records]
    if len(ids) != len(set(ids)) or any(r["end"] < r["start"] for r in records):
        raise ValueError(f"Invalid intervals: {path}")
    result = {
        "source": str(path.resolve()),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "records": len(records),
        "cancelled_intervals": sum(r["result"] == "cancelled" for r in records),
        "workloads": {},
    }
    for folder, count in [("100MSDCF", 56), ("06_mai_2026", 26)]:
        subset = [r for r in records if f"/{folder}/" in r["path"]]
        paths = sorted({r["path"] for r in subset if r["stage"] == "thumbnail.total"})[:count]
        if len(paths) != count:
            raise ValueError(f"Incomplete fixed filename cohort: {path}: {folder}")
        cohort = [r for r in subset if r["path"] in paths]
        stages = {}
        for stage in sorted({r["stage"] for r in cohort}):
            values = [r for r in cohort if r["stage"] == stage]
            durations = [r["duration_ms"] for r in values]
            stages[stage] = {
                "count": len(values), "median_ms": statistics.median(durations),
                "min_ms": min(durations), "max_ms": max(durations),
                "results": dict(collections.Counter(r["result"] for r in values)),
            }
        totals = [r for r in cohort if r["stage"] == "thumbnail.total"]
        if len(totals) != count or any(r["result"] != "finished" for r in totals):
            raise ValueError(f"Repeated/cancelled fixed cohort: {path}: {folder}")
        scans = [r for r in records if r["stage"] == "scan.discoveryAndPublication"
                 and r["path"].endswith("/" + folder)]
        result["workloads"][folder] = {
            "filenames": [Path(p).name for p in paths], "stages": stages,
            "scan_trials_ms": [r["duration_ms"] for r in scans],
            "cohort_request_window_ms": (max(r["end"] for r in totals)
                                          - min(r["start"] for r in totals)) * 1000,
            "first_request_to_first_delivery_ms": (min(r["end"] for r in totals)
                                                     - min(r["start"] for r in totals)) * 1000,
        }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = {"scope": "Fixed initial filename cohort, exploratory request timings; not painted viewport latency",
              "trials": [summarize(path) for path in args.logs]}
    args.output.write_text(json.dumps(output, indent=2) + "\n")
