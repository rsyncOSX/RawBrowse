#!/usr/bin/env python3
"""Prepare isolated app copies; never replaces the working project's pinned dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--package", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=False)
patch = args.root / "Docs/Performance/Patches/RawParserKit-thumbnail-executor.patch"
identities = {}
for variant in ["Baseline", "Candidate"]:
    root = args.output / variant
    app = root / "App"
    package = root / "RawParserKit"
    shutil.copytree(args.root, app, ignore=shutil.ignore_patterns(".git", "__pycache__", ".DS_Store"))
    shutil.copytree(args.package, package, ignore=shutil.ignore_patterns(".git", ".build", ".swiftpm"))
    for source in package.rglob("*.swift"):
        source.chmod(source.stat().st_mode | 0o200)
    if variant == "Candidate":
        subprocess.run(["git", "apply", "--check", str(patch.resolve())], cwd=package, check=True)
        subprocess.run(["git", "apply", str(patch.resolve())], cwd=package, check=True)
    project = app / "RawBrowse.xcodeproj/project.pbxproj"
    text = project.read_text()
    pattern = r'\t\tE9BCDDC72FF6962A004A4A95 /\* XCRemoteSwiftPackageReference "RawParserKit" \*/ = \{.*?\n\t\t\};'
    replacement = '''\t\tE9BCDDC72FF6962A004A4A95 /* XCLocalSwiftPackageReference "RawParserKit" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = ''' + json.dumps(str(package)) + ''';
\t\t};'''
    text, count = re.subn(pattern, lambda _: replacement, text, flags=re.DOTALL)
    assert count == 1, "Unexpected package reference; inspect project before changing it"
    project.write_text(text)
    identities[variant] = {
        "app": str(app), "package": str(package),
        "swift_source_hashes": {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted((app / "RawBrowse").rglob("*.swift"))},
        "parser_loader_sha256": hashlib.sha256((package / "Sources/RawParserKit/RawImageLoader.swift").read_bytes()).hexdigest(),
    }
assert identities["Baseline"]["swift_source_hashes"] == identities["Candidate"]["swift_source_hashes"]
(args.output / "identity.json").write_text(json.dumps(identities, indent=2) + "\n")
print(args.output)
