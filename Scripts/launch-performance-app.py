#!/usr/bin/env python3
"""Launch one verified, isolated GUI experiment process with a reproducible cache root."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--variant", required=True, choices=["baseline", "candidate"])
parser.add_argument("--state", required=True, choices=["empty", "warm"])
parser.add_argument("--trial", required=True, type=int)
args = parser.parse_args()
root = args.root.resolve()
runs = root / "RunsFinal"
runs.mkdir(exist_ok=True)
log = runs / f"{args.variant}-{args.state}-{args.trial}.jsonl"
if log.exists():
    raise SystemExit(f"Refusing to overwrite evidence: {log}")
processes = subprocess.check_output(["ps", "-axo", "pid,comm"], text=True).splitlines()
if any(line.strip().endswith("/RawBrowse.app/Contents/MacOS/RawBrowse") for line in processes):
    raise SystemExit("Close the previous RawBrowse experiment normally before launching another")
cache_manifest = runs / f"{args.variant}-{args.trial}-cache.json"
if args.state == "empty":
    if cache_manifest.exists():
        raise SystemExit("Trial cache identity already exists")
    cache_root = str(Path.home() / "Library/Containers/no.blogspot.RawBrowse/Data/tmp"
                     / f"performance-{args.variant}-{args.trial}-{uuid.uuid4()}")
    cache_manifest.write_text(json.dumps({"cache_root": cache_root}, indent=2) + "\n")
else:
    cache_root = json.loads(cache_manifest.read_text())["cache_root"]
app = root / (args.variant.title() + "Build") / "Build/Products/Release/RawBrowse.app"
subprocess.run(["open", "-n", "-a", str(app), "--env", "RAWBROWSE_PERFORMANCE_LOG=-",
                "--env", "RAWBROWSE_PERFORMANCE_CACHE_ROOT=" + cache_root,
                "--stderr", str(log)], check=True)
subprocess.run(["python3", str(Path(__file__).with_name("wait-for-image-delivery.py")),
                str(log), "--folder", "100MSDCF"], check=True, timeout=25)
records = []
for line in log.read_text().splitlines():
    try:
        records.append(json.loads(line))
    except ValueError:
        pass
configuration = next(r["fields"] for r in records if r.get("event") == "workspace.configuration")
if Path(configuration["executable"]).resolve() != (app / "Contents/MacOS/RawBrowse").resolve():
    raise SystemExit("Unexpected measured executable")
metadata = {"variant": args.variant, "state": args.state, "trial": args.trial,
            "cache_root": cache_root, "app": str(app), "log": str(log),
            "verified_at_unix": time.time(), "configuration": configuration}
log.with_suffix(".launch.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata))
