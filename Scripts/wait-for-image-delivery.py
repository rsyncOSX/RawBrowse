#!/usr/bin/env python3
"""Wait for explicit diagnostic delivery/drain events, not a guessed UI delay."""
import argparse
import json
from pathlib import Path
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
parser.add_argument("--folder", choices=["100MSDCF", "06_mai_2026"])
parser.add_argument("--drained", action="store_true")
parser.add_argument("--timeout", type=float, default=15)
args = parser.parse_args()
manifest = json.loads((Path(__file__).resolve().parents[1] / "Docs/Performance/Phase4-Workloads.json").read_text())
expected = set()
if args.folder:
    workload = next(w for w in manifest["workloads"] if w["path"].endswith("/" + args.folder))
    expected = {f["name"] for f in sorted(workload["files"], key=lambda f: f["name"])
                if f["name"].lower().endswith(".arw")}
    expected = set(sorted(expected)[:56 if args.folder == "100MSDCF" else 26])
deadline = time.monotonic() + args.timeout
while True:
    records = []
    if args.log.exists():
        for line in args.log.read_text().splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append(record)
    delivered = {Path(r["path"]).name for r in records
                 if r.get("stage") == "thumbnail.presentationDelivery" and r.get("result") == "image"
                 and (not args.folder or f"/{args.folder}/" in r["path"])}
    pending = set()
    for record in records:
        event = record.get("event", "")
        if event.endswith(".taskStarted"):
            pending.add(record["fields"]["task_id"])
        elif event.endswith(".taskFinished"):
            pending.discard(record["fields"]["task_id"])
    quiet = args.log.exists() and time.time() - args.log.stat().st_mtime >= 0.5
    if expected <= delivered and (not args.drained or (not pending and quiet)):
        print(f"Delivered {len(expected & delivered)}/{len(expected)}; pending owned image tasks {len(pending)}")
        break
    if time.monotonic() >= deadline:
        raise SystemExit(f"Incomplete: delivered {len(expected & delivered)}/{len(expected)}; pending {len(pending)}")
    time.sleep(0.1)
