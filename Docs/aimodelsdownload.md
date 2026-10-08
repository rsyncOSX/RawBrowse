+++
author = "Thomas Evensen"
title = "Download AI models"
date = "2026-09-26"
lastmod = "2026-09-30"
weight = 25
tags = ["ai", "models", "hugging-face", "core-ai", "background-assets", "release"]
categories = ["technical details"]
+++

# Download and prepare the three AI model packs

This is a terminal workbook for rebuilding RawCull's **DataComp CLIP**, **Meta
SAM 3**, and **Qwen3-VL-2B-Instruct** model packs from source and finishing with
three Apple Managed Background Assets `.aar` files. It was assembled on
September 26, 2026 from the local PhotoAIKit exporters, the RawCull release
runbook, and the existing layout in `/Users/thomas/ModelAssets/Release`.

Run each numbered block in **zsh** and inspect the indicated output before the
next block. The workbook builds in a fresh directory below
`/Users/thomas/ModelAssets`; it does not overwrite the three existing
`Release/Output/*.aar` files. Conversion is CPU and memory intensive and the
source downloads are several gigabytes. Keep ample free space for source
weights, intermediate models, three converted bundles, and three archives.

These commands produce **local release candidates**, not App Store approval.
After packaging, compare the new hashes with the application catalog and follow
the [publishing runbook](https://github.com/rsyncOSX/RawCull/blob/version-3.2.6/Docs/newmodels.md)
to update RawCull, upload the packs, and test a signed TestFlight build. A fresh conversion may produce different archive
bytes even when the same source model was used.

## 0. What will be produced

| Model | Permanent pack ID | Selected installed model path | Output archive |
|---|---|---|---|
| DataComp CLIP | `rawcull-clip-datacomp` | `Models/CLIP-DataComp` | `clip-datacomp.aar` |
| Meta SAM 3 | `rawcull-sam3` | `Models/SAM3` | `sam3.aar` |
| Qwen3-VL-2B-Instruct | `rawcull-qwen3-vl-2b` | `Models/Qwen/qwen3_vl_2b` | `qwen3-vl-2b.aar` |

The starting evidence is the RawCull repository at
`/Users/thomas/GitHub/RawCull/RawCull`, its sibling
`/Users/thomas/GitHub/RawCull/PhotoAIKit`, and the notices in
`RawCull/ModelAssets/Notices`. The old archive sizes and SHA-256 values in the
application catalog describe the **September 17, 2026 artifacts**, not expected
values for this rebuild. OpenAI CLIP and EfficientSAM are outside this
three-pack release.

## 1. Check the Mac and select tools

Install Xcode 27 with the Core AI and Background Assets tools and select it in
Xcode Settings or with `xcode-select`. Install `git` and `uv` if needed. The
commands below merely check the selected tools:

```zsh
set -e
set -o pipefail
RAWCULL_REPO='/Users/thomas/GitHub/RawCull/RawCull'
PHOTOAIKIT_REPO='/Users/thomas/GitHub/RawCull/PhotoAIKit'
MODEL_ASSETS='/Users/thomas/ModelAssets'

test -d "$RAWCULL_REPO/.git"
test -d "$PHOTOAIKIT_REPO/.git"
test -d "$MODEL_ASSETS"
command -v uv
command -v git
command -v python3
xcode-select -p
xcodebuild -version
xcrun ba-package --version
```

If `uv` is missing and Homebrew is available, install it with `brew install
uv`, then rerun the checks. Record the exact tool versions with the eventual
archive hashes. At the time this workbook was written the local Mac selected
Xcode 27.0 (27A266a) and `ba-package` 2.0; a later toolchain can produce
different output. The PhotoAIKit exporter scripts declare their Python
dependencies in their own `# /// script` blocks, so `uv run` creates the
appropriate isolated environments automatically. Do not combine the CLIP and
SAM dependency sets by hand: their `transformers` requirements differ.

## 2. Start a clean build directory

Paste this block into the same Terminal window that will run later blocks. If
you open a new window, rerun the variable definitions in this block and set
`BUILD_ROOT` to the directory printed by `echo`.

```zsh
set -e
set -o pipefail
RAWCULL_REPO='/Users/thomas/GitHub/RawCull/RawCull'
PHOTOAIKIT_REPO='/Users/thomas/GitHub/RawCull/PhotoAIKit'
MODEL_ASSETS='/Users/thomas/ModelAssets'
BUILD_ROOT="$(mktemp -d "$MODEL_ASSETS/Build-2026-09-26.XXXXXX")"
HF_HOME="$BUILD_ROOT/HuggingFace"
HF_HUB_CACHE="$HF_HOME/hub"
export HF_HOME HF_HUB_CACHE
mkdir -p "$BUILD_ROOT/Release/Models/Qwen" \
  "$BUILD_ROOT/Release/Notices" \
  "$BUILD_ROOT/Release/Packaging" \
  "$BUILD_ROOT/Release/Output" \
  "$BUILD_ROOT/Release/Evidence" \
  "$BUILD_ROOT/Tools"
echo "BUILD_ROOT=$BUILD_ROOT"
df -h "$MODEL_ASSETS"
```

This layout isolates the Hugging Face cache and the new release candidates.
Never run `rm -rf` against the existing `ModelAssets/Release` tree to make room.
For a later run, change the date in the `mktemp` template or leave it: the
random suffix still creates a separate directory.

## 3. Freeze source and exporter revisions

The model revisions recorded in the existing RawCull catalog are:

```zsh
CLIP_REV='4afec35ffe57a943d569ff7ee888061830164da8'
SAM_REV='3c879f39826c281e95690f02c7821c4de09afae7'
QWEN_REV='78448d793a7eb2f7a987a1da76d464384aa1becd'
CLIP_TOKENIZER_REV='3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268'
COREAI_MODELS_REV='475c585fdb0fe82a83c8f777f259e9414bd44c98'
```

`COREAI_MODELS_REV` is the revision pinned by the local PhotoAIKit package in
the September 2026 RawCull work. These revision labels are a **starting recipe**.
The old DataComp and Qwen provenance explicitly does not prove which exact
weight bytes their exporters consumed. This rebuild records the actual source
inventory so its evidence is stronger.

First save the repository states. If either repository has local changes to
the exporter, review them before proceeding:

```zsh
git -C "$RAWCULL_REPO" rev-parse HEAD | tee "$BUILD_ROOT/Release/Evidence/rawcull-commit.txt"
git -C "$PHOTOAIKIT_REPO" rev-parse HEAD | tee "$BUILD_ROOT/Release/Evidence/photoaikit-commit.txt"
git -C "$RAWCULL_REPO" status --short
git -C "$PHOTOAIKIT_REPO" status --short
shasum -a 256 "$PHOTOAIKIT_REPO/Tools/export_clip.py" \
  "$PHOTOAIKIT_REPO/Tools/export_sam3.py" \
  "$PHOTOAIKIT_REPO/Tools/select_sam3_asset.py" \
  | tee "$BUILD_ROOT/Release/Evidence/photoaikit-exporters-sha256.txt"
```

Get Apple's converter at the selected revision in the build directory. A
normal `git clone` also preserves its licence and Python project configuration.
If the pinned revision is unavailable, stop and choose a reviewed revision;
do not silently use the current `main` branch.

```zsh
git clone https://github.com/apple/coreai-models.git "$BUILD_ROOT/Tools/coreai-models"
git -C "$BUILD_ROOT/Tools/coreai-models" checkout --detach "$COREAI_MODELS_REV"
git -C "$BUILD_ROOT/Tools/coreai-models" rev-parse HEAD \
  | tee "$BUILD_ROOT/Release/Evidence/coreai-models-commit.txt"
```

## 4. Download immutable Hugging Face snapshots

SAM 3 is gated: sign in to Hugging Face in a browser, request/receive access to
`facebook/sam3`, accept its terms, and authenticate the terminal with
`uvx --from huggingface-hub hf auth login`. Do not paste your access token into
this workbook or a shell command. Qwen and DataComp are public, but checking
their model cards and current redistribution terms is still part of release
review. These downloads use [Hugging Face's CLI](https://huggingface.co/docs/huggingface_hub/guides/cli).

```zsh
uvx --from huggingface-hub hf auth whoami
uvx --from huggingface-hub hf download \
  laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K \
  --revision "$CLIP_REV" \
  --local-dir "$BUILD_ROOT/Source/CLIP-DataComp"
uvx --from huggingface-hub hf download facebook/sam3 \
  --revision "$SAM_REV" \
  --local-dir "$BUILD_ROOT/Source/SAM3"
uvx --from huggingface-hub hf download Qwen/Qwen3-VL-2B-Instruct \
  --revision "$QWEN_REV" \
  --local-dir "$BUILD_ROOT/Source/Qwen"
```

The exporters do not all take a `--revision` or `--source-dir` flag. To make
their ordinary model-ID lookups use the selected snapshots, populate the
isolated Hugging Face cache at the same revisions and bind its `main` refs to
those revisions. This is explicit, local to `BUILD_ROOT`, and leaves your
ordinary Hugging Face cache alone. The CLIP exporter also obtains the OpenAI
CLIP tokenizer, so cache it separately.

```zsh
uvx --from huggingface-hub hf download \
  laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K \
  --revision "$CLIP_REV"
uvx --from huggingface-hub hf download facebook/sam3 --revision "$SAM_REV"
uvx --from huggingface-hub hf download Qwen/Qwen3-VL-2B-Instruct \
  --revision "$QWEN_REV"
uvx --from huggingface-hub hf download openai/clip-vit-base-patch32 \
  --revision "$CLIP_TOKENIZER_REV"

mkdir -p "$HF_HUB_CACHE/models--laion--CLIP-ViT-B-32-256x256-DataComp-s34B-b86K/refs" \
  "$HF_HUB_CACHE/models--facebook--sam3/refs" \
  "$HF_HUB_CACHE/models--Qwen--Qwen3-VL-2B-Instruct/refs" \
  "$HF_HUB_CACHE/models--openai--clip-vit-base-patch32/refs"
printf '%s' "$CLIP_REV" > "$HF_HUB_CACHE/models--laion--CLIP-ViT-B-32-256x256-DataComp-s34B-b86K/refs/main"
printf '%s' "$SAM_REV" > "$HF_HUB_CACHE/models--facebook--sam3/refs/main"
printf '%s' "$QWEN_REV" > "$HF_HUB_CACHE/models--Qwen--Qwen3-VL-2B-Instruct/refs/main"
printf '%s' "$CLIP_TOKENIZER_REV" > "$HF_HUB_CACHE/models--openai--clip-vit-base-patch32/refs/main"
```

The first `--local-dir` downloads are the inspectable evidence copies; the
second downloads populate the cache actually used by the model-ID loaders.
Record source hashes, including every Qwen weight shard:

```zsh
find "$BUILD_ROOT/Source" -type f ! -name '.DS_Store' -print0 \
  | xargs -0 shasum -a 256 \
  | sort > "$BUILD_ROOT/Release/Evidence/source-files-sha256.txt"
rg 'safetensors|tokenizer.json|LICENSE' \
  "$BUILD_ROOT/Release/Evidence/source-files-sha256.txt" | head -80
```

Check that the expected source files exist before converting:

```zsh
test -f "$BUILD_ROOT/Source/SAM3/model.safetensors"
test -f "$BUILD_ROOT/Source/Qwen/config.json"
find "$BUILD_ROOT/Source/Qwen" -maxdepth 1 -name '*.safetensors' -print
find "$BUILD_ROOT/Source/CLIP-DataComp" -maxdepth 1 -type f -print
```

**DataComp binding limitation:** `open_clip.create_model_and_transforms` uses
the `datacomp_s34b_b86k` preset and may resolve its checkpoint through an
OpenCLIP configuration rather than the checked-out LAION directory. Run it
with the isolated cache and inspect the export log and cache entries. Do not
claim that the LAION file was consumed solely because it was downloaded. If
the resolved source differs, capture that actual source file, revision and
SHA-256, or adapt the exporter to accept an explicit local weight path before
release.

## 5. Convert DataComp CLIP

The PhotoAIKit exporter creates one two-function `.aimodel` plus tokenizer and
bundle metadata. Its default DataComp options use ViT-B/32 at 256 px,
`datacomp_s34b_b86k`, float16, and static shapes. The script itself pins the
Python packages, including `coreai-core==1.0.0b2` and
`coreai-torch==0.4.1`.

```zsh
cd "$PHOTOAIKIT_REPO"
export HF_HUB_OFFLINE=1
uv run Tools/export_clip.py \
  --model openclip-datacomp \
  --architecture ViT-B-32-256 \
  --pretrained datacomp_s34b_b86k \
  --dtype float16 \
  --output-dir "$BUILD_ROOT/Release/Models" \
  --bundle-name CLIP-DataComp \
  2>&1 | tee "$BUILD_ROOT/Release/Evidence/clip-export.log"
```

The exporter checks parity between the OpenCLIP tokenizer IDs and the saved
PhotoAIKit tokenizer. Stop if that check fails. `HF_HUB_OFFLINE=1` intentionally
prevents a network fallback to an unpinned source. If OpenCLIP needs a different
checkpoint repository, find its actual configured repository, pin and download
it, then rerun this block in a **new** build directory. Do not use `--overwrite`
until you have saved and reviewed the first result.

```zsh
test -f "$BUILD_ROOT/Release/Models/CLIP-DataComp/metadata.json"
test -f "$BUILD_ROOT/Release/Models/CLIP-DataComp/tokenizer/tokenizer.json"
test -f "$BUILD_ROOT/Release/Models/CLIP-DataComp/ViT-B-32-256-datacomp_s34b_b86k_float16_static.aimodel/main.mlirb"
cat "$BUILD_ROOT/Release/Models/CLIP-DataComp/metadata.json"
```

## 6. Convert Meta SAM 3

The SAM exporter downloads the gated checkpoint by model ID, exports a source
asset and an optimized runtime asset, and writes tokenizer and metadata. Select
the optimized `sam3_float16.aimodel` so the package contains the runtime asset
only. The selector refreshes the bundle fingerprint metadata.

```zsh
cd "$PHOTOAIKIT_REPO"
export HF_HUB_OFFLINE=1
uv run Tools/export_sam3.py \
  --model facebook/sam3 \
  --dtype float16 \
  --output-dir "$BUILD_ROOT/Release/Models" \
  --bundle-name SAM3 \
  2>&1 | tee "$BUILD_ROOT/Release/Evidence/sam3-export.log"

python3 Tools/select_sam3_asset.py sam3_float16.aimodel \
  --bundle-dir "$BUILD_ROOT/Release/Models/SAM3"
```

Inspect the result. The package selector below includes only the optimized
asset, tokenizer and metadata; it does not include any remaining
`*_source.aimodel` directory.

```zsh
test -f "$BUILD_ROOT/Release/Models/SAM3/metadata.json"
test -f "$BUILD_ROOT/Release/Models/SAM3/tokenizer/tokenizer.json"
test -f "$BUILD_ROOT/Release/Models/SAM3/sam3_float16.aimodel/main.mlirb"
cat "$BUILD_ROOT/Release/Models/SAM3/metadata.json"
```

## 7. Convert Qwen3-VL-2B-Instruct

Apple's [VLM exporter](https://github.com/apple/coreai-models/blob/main/python/src/coreai_models/vlm/export.py)
creates the text decoder, embedding lookup, vision encoder, tokenizer, and
`metadata.json` in a `qwen3_vl_2b` directory. Use the full model: do not set
`--num-layers` or `--skip-vision`. The existing RawCull bundle records a 4096
token context. The exporter has no `--revision` option, so the isolated cache
and offline mode from section 4 matter here. Its output directory is the
**parent** of `qwen3_vl_2b`.

```zsh
cd "$BUILD_ROOT/Tools/coreai-models"
export HF_HUB_OFFLINE=1
uv run coreai.vlm.export --list-models
uv run coreai.vlm.export qwen3-vl \
  --max-context-length 4096 \
  --compression none \
  --output-dir "$BUILD_ROOT/Release/Models/Qwen" \
  2>&1 | tee "$BUILD_ROOT/Release/Evidence/qwen-export.log"
```

If the pinned converter revision does not offer `qwen3-vl` or one of these
options, stop and inspect that revision's `--help`; record and review any
converter revision change. Qwen export can take a long time and use substantial
memory. A process killed by macOS needs a fresh build directory or a carefully
inspected incomplete-output cleanup before retrying.

```zsh
QWEN_BUNDLE="$BUILD_ROOT/Release/Models/Qwen/qwen3_vl_2b"
test -f "$QWEN_BUNDLE/metadata.json"
test -f "$QWEN_BUNDLE/tokenizer/tokenizer.json"
test -f "$QWEN_BUNDLE/qwen3_vl_2b.aimodel/main.mlirb"
test -f "$QWEN_BUNDLE/embed.aimodel/main.mlirb"
test -f "$QWEN_BUNDLE/vision.aimodel/main.mlirb"
python3 -m json.tool "$QWEN_BUNDLE/metadata.json"
```

Check that the metadata still names `Qwen/Qwen3-VL-2B-Instruct`, the three
assets, 448 px vision input, and 4096 context. This is a format check, not an
inference test. RawCull's Qwen provider must also load and run the bundle.

## 8. Stage licences, notices and build provenance

Copy the reviewed notice catalog from RawCull. These files include the complete
model, tokenizer, and Apple conversion-recipe notices used by the existing
release. Review their terms and dates against the newly downloaded sources
before redistribution. SAM 3's licence acceptance is required in RawCull.

```zsh
for name in CLIP-DataComp SAM3 Qwen; do
  ditto "$RAWCULL_REPO/ModelAssets/Notices/$name" \
    "$BUILD_ROOT/Release/Notices/$name"
done
find "$BUILD_ROOT/Release/Notices" -type f -maxdepth 2 -print | sort
```

Those checked-in `NOTICE.md` files describe earlier published versions. Mark
the staging copies as new candidates without changing their licence text:

```zsh
python3 - "$BUILD_ROOT" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]) / 'Release/Notices'
replacements = {
    'CLIP-DataComp': (
        'RawCull publishes this pack in the v2 model release. The release catalog\n'
        'records its download size and version, while the release host records the\n'
        'archive checksum. This notice catalog records the upstream reference revision,\n'
        'runtime fingerprint, and complete accompanying licence notices.',
        'This converted bundle is a new local release candidate. Its final archive\n'
        'size, SHA-256, Apple-assigned version, and review status must be recorded\n'
        'after packaging and upload.'),
    'SAM3': (
        'The Apple-hosted asset pack is enabled for download at the project owner\'s\n'
        'direction. Its archive byte size and SHA-256 are recorded in the external\n'
        'release evidence after packaging, while the host-correct in-pack release record\n'
        'is in `PROVENANCE.json`. This release decision does not claim an independent\n'
        'legal review. Verified licence acceptance remains required.',
        'This converted bundle is a new local release candidate. Record its archive\n'
        'size, SHA-256, Apple-assigned version, and review status after packaging\n'
        'and upload. Verified SAM licence acceptance remains required.'),
    'Qwen': (
        'RawCull publishes this pack in the v3 model release. The release catalog\n'
        'records its download size and version, while the release host records the\n'
        'archive checksum.',
        'This converted bundle is a new local release candidate. Record its final\n'
        'archive size, SHA-256, Apple-assigned version, and review status after\n'
        'packaging and upload.'),
}
for name, (old, new) in replacements.items():
    path = base / name / 'NOTICE.md'
    content = path.read_text()
    if content.count(old) != 1:
        raise RuntimeError(f'Expected release paragraph not found: {path}')
    path.write_text(content.replace(old, new))
PY
```

The copied `PROVENANCE.json` files describe the **old release**. Replace only
the staging copies with a clearly identified record of this build. The script
below preserves the licence inventory, writes the actual converted-component
hashes, and points to the source inventory. It intentionally has no final `.aar`
hash because that hash cannot be embedded inside its own archive.

```zsh
python3 - "$BUILD_ROOT" "$CLIP_REV" "$SAM_REV" "$QWEN_REV" <<'PY'
import datetime, hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
revisions = dict(zip(('CLIP-DataComp', 'SAM3', 'Qwen'), sys.argv[2:]))
models = {
    'CLIP-DataComp': root / 'Release/Models/CLIP-DataComp',
    'SAM3': root / 'Release/Models/SAM3',
    'Qwen': root / 'Release/Models/Qwen/qwen3_vl_2b',
}
for name, model_dir in models.items():
    notice_dir = root / 'Release/Notices' / name
    old = json.loads((notice_dir / 'PROVENANCE.json').read_text())
    components = {}
    for path in sorted(model_dir.rglob('main.mlirb')):
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
                digest.update(chunk)
        components[str(path.relative_to(model_dir))] = digest.hexdigest()
    record = {
        'catalog_version': 2,
        'release_status': 'candidate',
        'release': {
            'hosting': 'apple',
            'app_bundle_id': 'no.blogspot.RawCull',
            'asset_pack_id': {
                'CLIP-DataComp': 'rawcull-clip-datacomp',
                'SAM3': 'rawcull-sam3',
                'Qwen': 'rawcull-qwen3-vl-2b',
            }[name],
            'packaging_date': datetime.date.today().isoformat(),
            'processing_status': 'not-uploaded',
            'review_state': 'not-submitted',
        },
        'model': {
            'bundle': old.get('model', {}).get('bundle', name),
            'converted_main_mlirb_sha256': components,
        },
        'upstream': {
            'project': old.get('upstream', {}).get('project'),
            'selected_revision': revisions[name],
            'source_inventory': 'Release/Evidence/source-files-sha256.txt',
            'exporter_binding_note': 'Verify exporter log and isolated cache before claiming exact source binding.',
        },
        'conversion': {
            'photoaikit_commit_file': 'Release/Evidence/photoaikit-commit.txt',
            'coreai_models_commit_file': 'Release/Evidence/coreai-models-commit.txt',
        },
        'licences': old.get('licences', []),
    }
    (notice_dir / 'PROVENANCE.json').write_text(json.dumps(record, indent=2) + '\n')
PY
```

The staging provenance format is release-candidate evidence; it is **not** a
drop-in replacement for RawCull's checked-in `PROVENANCE.json`. After packaging,
update the repository record using its full validated schema and the final
archive hash, size, App Store Connect pack version, and processing state.

## 9. Create the three packaging manifests

These selector paths are relative to the current directory used by
`ba-package`, which must be `BUILD_ROOT/Release`. Keep the permanent IDs and
installed paths identical to RawCull's catalog.

```zsh
cat > "$BUILD_ROOT/Release/Packaging/clip-datacomp.json" <<'JSON'
{
  "assetPackID": "rawcull-clip-datacomp",
  "downloadPolicy": { "onDemand": {} },
  "fileSelectors": [
    { "file": "Models/CLIP-DataComp/metadata.json" },
    { "directory": "Models/CLIP-DataComp/tokenizer" },
    { "directory": "Models/CLIP-DataComp/ViT-B-32-256-datacomp_s34b_b86k_float16_static.aimodel" },
    { "directory": "Notices/CLIP-DataComp" }
  ],
  "platforms": ["macOS"]
}
JSON

cat > "$BUILD_ROOT/Release/Packaging/sam3.json" <<'JSON'
{
  "assetPackID": "rawcull-sam3",
  "downloadPolicy": { "onDemand": {} },
  "fileSelectors": [
    { "file": "Models/SAM3/metadata.json" },
    { "directory": "Models/SAM3/tokenizer" },
    { "directory": "Models/SAM3/sam3_float16.aimodel" },
    { "directory": "Notices/SAM3" }
  ],
  "platforms": ["macOS"]
}
JSON

cat > "$BUILD_ROOT/Release/Packaging/qwen3-vl-2b.json" <<'JSON'
{
  "assetPackID": "rawcull-qwen3-vl-2b",
  "downloadPolicy": { "onDemand": {} },
  "fileSelectors": [
    { "file": "Models/Qwen/qwen3_vl_2b/metadata.json" },
    { "directory": "Models/Qwen/qwen3_vl_2b/tokenizer" },
    { "directory": "Models/Qwen/qwen3_vl_2b/embed.aimodel" },
    { "directory": "Models/Qwen/qwen3_vl_2b/qwen3_vl_2b.aimodel" },
    { "directory": "Models/Qwen/qwen3_vl_2b/vision.aimodel" },
    { "directory": "Notices/Qwen" }
  ],
  "platforms": ["macOS"]
}
JSON

for slug in clip-datacomp sam3 qwen3-vl-2b; do
  python3 -m json.tool "$BUILD_ROOT/Release/Packaging/$slug.json" >/dev/null
done
```

## 10. Inspect and freeze the selected input files

`.DS_Store` files are present in the older `ModelAssets/Release` directories;
the new candidate should not include them. Do not delete anything from the old
release. Check the fresh selected directories and resolve any unexpected
symlink or secret before packaging.

```zsh
cd "$BUILD_ROOT/Release"
find Models/CLIP-DataComp Models/SAM3 Models/Qwen/qwen3_vl_2b \
  Notices/CLIP-DataComp Notices/SAM3 Notices/Qwen \
  \( -name '.DS_Store' -o -type l \) -print

find Models/CLIP-DataComp Models/SAM3 Models/Qwen/qwen3_vl_2b \
  Notices/CLIP-DataComp Notices/SAM3 Notices/Qwen \
  -type f -print0 | xargs -0 shasum -a 256 | sort \
  > Evidence/selected-inputs-sha256.txt

for slug in clip-datacomp sam3 qwen3-vl-2b; do
  xcrun ba-package evaluate "Packaging/$slug.json" \
    | tee "Evidence/$slug-evaluate.txt"
done
```

Read all three `Evidence/*-evaluate.txt` files. Each list should contain only
its model bundle, tokenizer, metadata, and matching notice directory. The
Qwen pack needs all three `.aimodel` directories. No source weight files,
download cache, old archive, or other model should be selected. If the
evaluation output is wrong, fix the manifest and rerun evaluation and the
input inventory before packaging.

## 11. Build the three `.aar` files

`ba-package` creates Background Assets archives; `.aar` is not a ZIP file.
Run it from `BUILD_ROOT/Release` so the relative file selectors resolve.

```zsh
cd "$BUILD_ROOT/Release"
xcrun ba-package package Packaging/clip-datacomp.json \
  --output-path Output/clip-datacomp.aar --verbose \
  2>&1 | tee Evidence/clip-datacomp-package.log

xcrun ba-package package Packaging/sam3.json \
  --output-path Output/sam3.aar --verbose \
  2>&1 | tee Evidence/sam3-package.log

xcrun ba-package package Packaging/qwen3-vl-2b.json \
  --output-path Output/qwen3-vl-2b.aar --verbose \
  2>&1 | tee Evidence/qwen3-vl-2b-package.log
```

Do not edit an archive after this point. Any changed model, metadata, notice,
or manifest requires another `ba-package package` run and a new hash. For the
three existing App Store Connect pack records, a changed archive will become a
new pack **version** under the same permanent ID.

## 12. Verify and record the result

```zsh
cd "$BUILD_ROOT/Release"
for slug in clip-datacomp sam3 qwen3-vl-2b; do
  test -s "Output/$slug.aar"
  stat -f '%N|%z bytes' "Output/$slug.aar"
  shasum -a 256 "Output/$slug.aar"
  shasum -a 256 "Packaging/$slug.json"
done | tee Evidence/archive-and-manifest-sha256.txt

find Output -maxdepth 1 -type f -name '*.aar' -print | sort
```

The last command must print exactly these three paths:

```text
Output/clip-datacomp.aar
Output/qwen3-vl-2b.aar
Output/sam3.aar
```

Compare the final `selected-inputs-sha256.txt` with a fresh hash pass to catch
any source mutation while the archives were built:

```zsh
find Models/CLIP-DataComp Models/SAM3 Models/Qwen/qwen3_vl_2b \
  Notices/CLIP-DataComp Notices/SAM3 Notices/Qwen \
  -type f -print0 | xargs -0 shasum -a 256 | sort \
  > Evidence/selected-inputs-after-sha256.txt
diff -u Evidence/selected-inputs-sha256.txt \
  Evidence/selected-inputs-after-sha256.txt
```

An empty `diff` and exit status 0 confirm that the selected inputs remained
unchanged during packaging. Record the `BUILD_ROOT` path, Xcode version,
exporter commits, source hashes, and all three archive hashes with the release
candidate. The files are at:

```text
<BUILD_ROOT>/Release/Output/clip-datacomp.aar
<BUILD_ROOT>/Release/Output/sam3.aar
<BUILD_ROOT>/Release/Output/qwen3-vl-2b.aar
```

## 13. Before uploading or calling these release files

1. Verify that the DataComp exporter actually consumed the pinned checkpoint;
   the downloaded LAION snapshot alone does not prove it. For all three packs,
   retain actual source-weight hashes and exporter logs.
2. Review the current model licences and all copied notice files. Keep the
   correct notice directory inside each `.aar`.
3. Run RawCull's `make verify-model-provenance`, catalog and release-metadata
   tests, and release preflight **after** updating its manifest template,
   Swift catalog, and checked-in provenance to the new archive values. Never
   leave the old archive SHA-256 in the app catalog for new `.aar` files.
4. If uploading, use the existing `rawcull-clip-datacomp`, `rawcull-sam3`, and
   `rawcull-qwen3-vl-2b` App Store Connect records. Follow
   [`RawCull/Docs/newmodels.md`](https://github.com/rsyncOSX/RawCull/blob/version-3.2.6/Docs/newmodels.md)
   for `xcrun altool`, API-key handling, processing checks, and TestFlight
   verification. The `AppStore` build must use Apple hosting and the matching
   App Group. A successful local `.aar` build does not test runtime inference.

### If a step fails

| Symptom | Check |
|---|---|
| `401`/`403` downloading SAM 3 | Hugging Face approval and `hf auth whoami`; accept the gated model terms. |
| Offline source missing | Check the isolated `HF_HUB_CACHE` and the model's `refs/main`; download the exact revision before re-exporting. |
| CLIP tokenizer parity failure | Do not package; inspect the tokenizer source and OpenCLIP configuration. |
| SAM export leaves source asset | Package only the optimized asset selected by `select_sam3_asset.py`. |
| Qwen bundle lacks `vision.aimodel` | Rebuild with a converter that supports Qwen VLM and without `--skip-vision`. |
| `ba-package evaluate` lists extra files | Correct its `fileSelectors`; evaluate again before packaging. |
| Archive hash differs from the old release | Expected for a new conversion; update catalog and provenance before upload. |

The source commands and pack layout come from [PhotoAIKit's export tools](https://github.com/rsyncOSX/PhotoAIKit/tree/main/Tools),
[Apple's Core AI model recipes](https://github.com/apple/coreai-models),
[Apple's managed pack documentation](https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs),
and the RawCull release runbook linked above. Verify the exact checkout used
for a release: repository `main` branches and tool versions can change.
