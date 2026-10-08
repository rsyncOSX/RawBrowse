+++
author = "Thomas Evensen"
title = "Build and publish RawBrowse AI models"
date = "2026-09-26"
lastmod = "2026-10-08"
weight = 25
tags = ["ai", "models", "hugging-face", "core-ai", "github", "release"]
categories = ["technical details"]
+++

# Build CLIP and SAM 3 for RawBrowse

This terminal workbook builds two complete PhotoAIKit-compatible Core AI
bundles: **DataComp CLIP** for semantic search and image similarity, and **Meta
SAM 3** for subject review. Build assets under `/Users/thomas/ModelAssetsV2` and
publish their files to [rsyncOSX/AI-models](https://github.com/rsyncOSX/AI-models).
The app repository is [RawBrowse](https://github.com/rsyncOSX/RawBrowse).

Run the numbered blocks in the same **zsh** session. Conversion downloads
several gigabytes and needs space for source weights, caches, intermediate
assets, and both runtime bundles. Each run creates a separate build directory.
The commands below are instructions to run locally; updating this guide does
not download, convert, or publish models.

## 1. Set paths and check tools

```zsh
set -e
set -o pipefail
RAWBROWSE_REPO='/Users/thomas/GitHub/RawCull/RawBrowse'
PHOTOAIKIT_REPO='/Users/thomas/GitHub/RawCull/PhotoAIKit'
MODEL_ASSETS_V2='/Users/thomas/ModelAssetsV2'

test -f "$RAWBROWSE_REPO/RawBrowse.xcodeproj/project.pbxproj"
test -f "$PHOTOAIKIT_REPO/Package.swift"
command -v uv
command -v git
command -v python3
xcode-select -p
xcodebuild -version
mkdir -p "$MODEL_ASSETS_V2"
BUILD_ROOT="$(mktemp -d "$MODEL_ASSETS_V2/Build-2026-10-08.XXXXXX")"
mkdir -p "$BUILD_ROOT/Release/Models" "$BUILD_ROOT/Release/Runtime" \
  "$BUILD_ROOT/Release/Output" "$BUILD_ROOT/Release/Evidence" \
  "$BUILD_ROOT/Tools"
export HF_HOME="$BUILD_ROOT/HuggingFace"
export HF_HUB_CACHE="$HF_HOME/hub"
echo "BUILD_ROOT=$BUILD_ROOT"
df -h "$MODEL_ASSETS_V2"
```

Use Xcode 27 and Apple Silicon, matching RawBrowse's macOS 27 requirement. If
`uv` is missing, install it before continuing. Save `BUILD_ROOT` so later
terminal sessions can resume the same candidate. Keep all existing build runs.

## 2. Freeze PhotoAIKit and record the current CoreAI pin

The local PhotoAIKit checkout on October 8, 2026 is commit
`b7265ab168a1dd009a3a6c26ebc367f4e6fa137c` and pins `apple/coreai-models` to
`1953c4f90ba0214c1abc7bebcb9be5107e329a46` in `Package.swift`. The block below
reads the pin from the checkout used for this build instead of retaining an
older hard-coded revision.

Review `git status` first. Commit any intended exporter changes before freezing
the checkout: `git archive HEAD` includes committed files only.

```zsh
git -C "$PHOTOAIKIT_REPO" status --short
git -C "$RAWBROWSE_REPO" rev-parse HEAD \
  | tee "$BUILD_ROOT/Release/Evidence/rawbrowse-commit.txt"
git -C "$PHOTOAIKIT_REPO" rev-parse HEAD \
  | tee "$BUILD_ROOT/Release/Evidence/photoaikit-commit.txt"
EXPORTER_REPO="$BUILD_ROOT/Tools/PhotoAIKit"
mkdir -p "$EXPORTER_REPO"
git -C "$PHOTOAIKIT_REPO" archive HEAD | tar -x -C "$EXPORTER_REPO"
COREAI_MODELS_REV="$(python3 - "$EXPORTER_REPO/Package.swift" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'url:\s*"https://github.com/apple/coreai-models.git",\s*revision:\s*"([0-9a-f]{40})"', text)
if not match:
    raise SystemExit('Expected an explicit CoreAI revision in PhotoAIKit/Package.swift')
print(match.group(1))
PY
)"
printf '%s\n' "$COREAI_MODELS_REV" \
  | tee "$BUILD_ROOT/Release/Evidence/coreai-models-pin.txt"
git clone https://github.com/apple/coreai-models.git "$BUILD_ROOT/Tools/coreai-models"
git -C "$BUILD_ROOT/Tools/coreai-models" checkout --detach "$COREAI_MODELS_REV"
git -C "$BUILD_ROOT/Tools/coreai-models" rev-parse HEAD \
  | tee "$BUILD_ROOT/Release/Evidence/coreai-models-commit.txt"
shasum -a 256 "$EXPORTER_REPO/Tools/export_clip.py" \
  "$EXPORTER_REPO/Tools/export_sam3.py" \
  "$EXPORTER_REPO/Tools/select_sam3_asset.py" \
  | tee "$BUILD_ROOT/Release/Evidence/exporters-sha256.txt"
```

**Runtime pin versus conversion tools:** the CoreAI revision above is the Swift
runtime dependency. PhotoAIKit's `Tools/export_clip.py` and `Tools/export_sam3.py`
are separate Python exporters adapted from Apple's recipes. They currently
specify `coreai-core==1.0.0b2` and `coreai-torch==0.4.1` in their script dependency
blocks. Cloning a newer `coreai-models` checkout does not change those exporters
or their Python dependencies. Use the frozen PhotoAIKit tools below to preserve
its bundle metadata and fingerprints. If adopting newer upstream conversion
changes, integrate and verify those changes in PhotoAIKit first, then start a
new candidate. Let `uv run` use each script's own dependency set.

Before runtime validation, ensure RawBrowse resolves the intended PhotoAIKit
commit and its CoreAI dependency. Inspect
`RawBrowse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
a newer sibling checkout alone does not update RawBrowse's package resolution.

## 3. Download pinned source weights and tokenizer

These are the model and tokenizer revisions recorded by RawBrowse's current
catalog. A newer converter does not require changing the source checkpoint.
Record a reviewed replacement revision explicitly if you choose newer weights.

SAM 3 requires access to `facebook/sam3` on Hugging Face and acceptance of its
terms. Authenticate with `hf auth login`; keep the token out of commands and
release evidence. See the [Hugging Face CLI documentation](https://huggingface.co/docs/huggingface_hub/guides/cli).

```zsh
CLIP_REV='4afec35ffe57a943d569ff7ee888061830164da8'
SAM_REV='3c879f39826c281e95690f02c7821c4de09afae7'
CLIP_TOKENIZER_REV='3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268'
uvx --from huggingface-hub hf auth login
uvx --from huggingface-hub hf auth whoami
uvx --from huggingface-hub hf download \
  laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K \
  --revision "$CLIP_REV" --local-dir "$BUILD_ROOT/Source/CLIP-DataComp"
uvx --from huggingface-hub hf download facebook/sam3 \
  --revision "$SAM_REV" --local-dir "$BUILD_ROOT/Source/SAM3"

uvx --from huggingface-hub hf download \
  laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K --revision "$CLIP_REV"
uvx --from huggingface-hub hf download facebook/sam3 --revision "$SAM_REV"
uvx --from huggingface-hub hf download openai/clip-vit-base-patch32 \
  --revision "$CLIP_TOKENIZER_REV"
mkdir -p "$HF_HUB_CACHE/models--laion--CLIP-ViT-B-32-256x256-DataComp-s34B-b86K/refs" \
  "$HF_HUB_CACHE/models--facebook--sam3/refs" \
  "$HF_HUB_CACHE/models--openai--clip-vit-base-patch32/refs"
printf '%s' "$CLIP_REV" > "$HF_HUB_CACHE/models--laion--CLIP-ViT-B-32-256x256-DataComp-s34B-b86K/refs/main"
printf '%s' "$SAM_REV" > "$HF_HUB_CACHE/models--facebook--sam3/refs/main"
printf '%s' "$CLIP_TOKENIZER_REV" > "$HF_HUB_CACHE/models--openai--clip-vit-base-patch32/refs/main"
find "$BUILD_ROOT/Source" -type f ! -path '*/.cache/*' ! -name '.DS_Store' -print0 \
  | xargs -0 shasum -a 256 | sort \
  > "$BUILD_ROOT/Release/Evidence/source-files-sha256.txt"
export HF_HUB_OFFLINE=1
```

The first downloads retain inspectable source copies; the second populate the
isolated cache used by model-ID loaders. Setting its `refs/main` files binds
those lookups to the selected snapshots. Offline conversion prevents fallback
to an unpinned download.

The DataComp exporter uses OpenCLIP's `datacomp_s34b_b86k` preset, which can
resolve a different checkpoint repository from the LAION evidence copy. Check
its export log and actual cached weight file. If offline export reports a
missing checkpoint, identify OpenCLIP's configured source, download a pinned
snapshot into this isolated cache, and record its actual SHA-256 before
retrying. Do not claim exact source binding from the evidence copy alone.

## 4. Export the two complete model bundles

```zsh
cd "$EXPORTER_REPO"
uv run Tools/export_clip.py \
  --model openclip-datacomp --architecture ViT-B-32-256 \
  --pretrained datacomp_s34b_b86k --dtype float16 \
  --output-dir "$BUILD_ROOT/Release/Models" --bundle-name CLIP-DataComp \
  2>&1 | tee "$BUILD_ROOT/Release/Evidence/clip-export.log"

uv run Tools/export_sam3.py \
  --model facebook/sam3 --dtype float16 \
  --output-dir "$BUILD_ROOT/Release/Models" --bundle-name SAM3 \
  2>&1 | tee "$BUILD_ROOT/Release/Evidence/sam3-export.log"
python3 Tools/select_sam3_asset.py sam3_float16.aimodel \
  --bundle-dir "$BUILD_ROOT/Release/Models/SAM3"

for name in CLIP-DataComp SAM3; do
  test -f "$BUILD_ROOT/Release/Models/$name/metadata.json"
  test -f "$BUILD_ROOT/Release/Models/$name/tokenizer/tokenizer.json"
  python3 -m json.tool "$BUILD_ROOT/Release/Models/$name/metadata.json"
done
```

CLIP contains both image and text encoder functions in one runtime asset. Its
exporter checks tokenizer parity; resolve a failed check before publication.
SAM 3 includes its optimized runtime asset, tokenizer, and metadata. The SAM
selector updates `assets.main` and the runtime fingerprint. Source assets stay
in the conversion directory and are excluded from the publication bundle.

## 5. Stage runtime assets and notices

Read `assets.main` from each bundle's metadata rather than guessing a filename.
Copy that entire `.aimodel` directory, all tokenizer resources, metadata, and
notices. The stage is the exact model root RawBrowse will install.

```zsh
python3 - "$BUILD_ROOT" "$RAWBROWSE_REPO" <<'PY'
import json, pathlib, shutil, sys
root, repo = map(pathlib.Path, sys.argv[1:])
for name, model_id in [('CLIP-DataComp', 'clip-datacomp'), ('SAM3', 'sam3')]:
    source = root / 'Release/Models' / name
    destination = root / 'Release/Runtime' / model_id
    if destination.exists():
        raise SystemExit(f'Already staged: {destination}; use a new candidate directory')
    metadata = json.loads((source / 'metadata.json').read_text())
    asset_name = metadata['assets']['main']
    if pathlib.Path(asset_name).name != asset_name:
        raise SystemExit(f'Unexpected runtime asset name: {asset_name}')
    asset = source / asset_name
    if not (asset / 'main.mlirb').is_file():
        raise SystemExit(f'Missing complete runtime asset: {asset}')
    destination.mkdir()
    shutil.copy2(source / 'metadata.json', destination / 'metadata.json')
    shutil.copytree(asset, destination / asset_name)
    shutil.copytree(source / 'tokenizer', destination / 'tokenizer')
    shutil.copytree(repo / 'ModelAssets/Notices' / name, destination / 'Notices')
PY
```

Review the staged notices against the source licences. Preserve the complete
licence texts. Copied `PROVENANCE.json` and release paragraphs in `NOTICE.md`
refer to historical artifacts: replace those staging records with this
candidate's PhotoAIKit commit, CoreAI pin, source revisions, exporter hashes,
and converted asset fingerprints before publication. Record hosting as GitHub
and the app as RawBrowse; use model IDs `clip-datacomp` and `sam3`. Keep the
licence inventory. SAM 3's verified licence acceptance remains required in the
app. See [the current publishing instructions](../ModelAssets/README.md).

## 6. Generate GitHub release files and the download manifest

RawBrowse reads
`https://raw.githubusercontent.com/rsyncOSX/AI-models/main/manifest.json`.
Its schema is `schemaVersion: 1`, containing two `models` entries with IDs
`clip-datacomp` and `sam3`. Each entry lists **every runtime file** using a
model-relative `path`, HTTPS `url`, exact `byteCount`, and lowercase `sha256`.

The app downloads individual files; it does not extract ZIP or Background
Assets archives. GitHub release assets have flat names, so the script generates
unique upload names while retaining the original paths in the manifest.
[GitHub limits each release asset to under 2 GiB](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas)
and permits up to 1,000 assets per release. This generator checks both limits.

Choose an unused release tag. Do not replace files behind URLs in an already
published manifest.

```zsh
MODEL_RELEASE_TAG='models-v2-2026-10-08'
python3 - "$BUILD_ROOT" "$MODEL_RELEASE_TAG" <<'PY'
import hashlib, json, pathlib, re, shutil, sys
root = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', tag):
    raise SystemExit('Use a simple immutable release tag')
output = root / 'Release/Output'
assets = output / 'assets'
if assets.exists():
    raise SystemExit('Output assets already exist; use a new candidate directory')
assets.mkdir()
manifest = {'schemaVersion': 1, 'models': []}
asset_count = 0
for model_id in ['clip-datacomp', 'sam3']:
    source = root / 'Release/Runtime' / model_id
    files = []
    for path in sorted(source.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Symlinks are not publishable: {path}')
        if not path.is_file():
            continue
        relative = path.relative_to(source).as_posix()
        if path.name == '.DS_Store' or '.cache' in path.parts:
            continue
        size = path.stat().st_size
        if not 0 < size < 2 * 1024**3:
            raise SystemExit(f'File must be nonempty and under 2 GiB: {path}')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        upload_name = f'{model_id}-{len(files):04d}.bin'
        shutil.copy2(path, assets / upload_name)
        files.append({
            'path': relative,
            'url': f'https://github.com/rsyncOSX/AI-models/releases/download/{tag}/{upload_name}',
            'byteCount': size,
            'sha256': digest.hexdigest(),
        })
    if not files:
        raise SystemExit(f'No files in {source}')
    asset_count += len(files)
    manifest['models'].append({'id': model_id, 'files': files})
if asset_count > 1000:
    raise SystemExit('More than 1,000 assets; use separate release tags and adjust URLs')
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Prepared {asset_count} release assets and {output / "manifest.json"}')
PY
python3 -m json.tool "$BUILD_ROOT/Release/Output/manifest.json" >/dev/null
shasum -a 256 "$BUILD_ROOT/Release/Output/manifest.json" \
  | tee "$BUILD_ROOT/Release/Evidence/manifest-sha256.txt"
```

Do not edit runtime files after this step. Any changed metadata, weights,
notices, or tokenizer requires a fresh manifest and newly verified assets.
Keep source weights, caches, exporter logs, and authentication files out of
`Release/Output/assets`.

## 7. Verify the staged files before publication

```zsh
python3 - "$BUILD_ROOT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'Release/Output/manifest.json').read_text())
assert manifest['schemaVersion'] == 1
assert [m['id'] for m in manifest['models']] == ['clip-datacomp', 'sam3']
for model in manifest['models']:
    total = 0
    for file in model['files']:
        upload_name = file['url'].rsplit('/', 1)[1]
        for path in [root / 'Release/Runtime' / model['id'] / file['path'],
                     root / 'Release/Output/assets' / upload_name]:
            assert path.stat().st_size == file['byteCount'], path
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            assert digest.hexdigest() == file['sha256'], path
        total += file['byteCount']
    print(model['id'], len(model['files']), 'files;', total, 'download bytes')
PY
```

Record those totals for RawBrowse's estimated download/installed sizes in
`CLIPModelDownloadCatalog.swift`. Update its source revisions and model version
if they changed. The live GitHub manifest supplies file checksums; old Apple
archive checksums are not applicable to these files.

## 8. Publish and validate in RawBrowse

1. Create the public `rsyncOSX/AI-models` repository with a `main` branch.
2. Create a release using `MODEL_RELEASE_TAG` and upload every file from
   `Release/Output/assets`. Keep the generated flat names unchanged. For large
   file lists, upload in batches using GitHub's release UI or `gh release upload`.
3. Publish the release and check that all asset URLs can be downloaded without
   authentication. Publish `Release/Output/manifest.json` as **`manifest.json`
   at the root of `main` only after the assets are available**. A manifest
   uploaded solely as a release attachment will not be discovered by RawBrowse.
4. Confirm RawBrowse's resolved PhotoAIKit/CoreAI revisions, build the app, and
   open **Settings > AI Models > Download AI Models**. Accept the SAM licence,
   download both models, and verify their installed locations with Show in Finder.
5. Build a CLIP catalog index, run semantic search and Find Similar, then run
   SAM 3 Subject Detail review. Check a representative set of photos for useful
   results; valid metadata alone does not demonstrate inference compatibility.
6. Test cancellation, retry, removal, and a clean redownload. Relaunch offline
   to verify both installed bundles remain usable. Existing installed models are
   reused; remove and redownload to test a new publication.

RawBrowse installs under its Application Support directory:

| Model | Download manifest ID | Installed model root |
|---|---|---|
| DataComp CLIP | `clip-datacomp` | `RawBrowse/AI-models/clip-datacomp` |
| Meta SAM 3 | `sam3` | `RawBrowse/AI-models/sam3` |

All model paths in the manifest are relative to those roots. Include the full
runtime asset directory and tokenizer, not just `main.mlirb`. RawBrowse checks
file size and SHA-256 and stages every file before installation.

## Troubleshooting

| Symptom | Check |
|---|---|
| SAM download returns 401/403 | Hugging Face access approval, accepted terms, and `hf auth whoami`. |
| Offline export cannot find weights | Actual exporter source repository, isolated cache snapshot, and `refs/main`. |
| CLIP tokenizer parity failure | Tokenizer source and OpenCLIP configuration before rebuilding. |
| New Swift pin but unchanged conversion output | Python exporters have separate pinned dependencies; inspect their script headers and source. |
| App reports models are not published | Public `main/manifest.json` and published release assets. |
| Model file fails checksum verification | Manifest corresponds to the exact uploaded bytes and release tag. |
| Bundle validates but inference fails | Full runtime files, metadata fingerprints, and RawBrowse's resolved PhotoAIKit/CoreAI revisions. |

Reference implementations: [PhotoAIKit export tools](https://github.com/rsyncOSX/PhotoAIKit/tree/main/Tools),
[the recorded CoreAI revision](https://github.com/apple/coreai-models/tree/1953c4f90ba0214c1abc7bebcb9be5107e329a46),
and RawBrowse's [model publishing instructions](../ModelAssets/README.md) and
[manifest template](../ModelAssets/manifest.template.json).
