# RawBrowse

RawBrowse is a macOS SwiftUI photo browser with local CLIP indexing, semantic search, and SAM 3 subject review. It browses and previews JPEG, PNG, HEIC/HEIF, TIFF, Sony ARW, and DNG files, and provides recursive semantic search over supported image formats.

## Source organization

`RawBrowse/Main` contains the app entry points, scene dependency injection,
and the browser composition root. `RawBrowse/Features` groups browser,
zoom, RAW9, AI, downloads, and settings code with their views.
`RawBrowse/Infrastructure` holds shared image loading, access leases,
concurrency helpers, and logging. See [the implementation record](Docs/modularization.md)
and [source relocation inventory](Docs/source-layout.md) for ownership and paths.

## Requirements

- macOS 27 or later
- **Apple Silicon** (M-series) only
- Xcode 27 and Swift 6 to build from source
- AI features require the corresponding downloaded Core AI model bundle; folder browsing does not require AI models.

## Features

- Add local folders through the macOS folder picker.
- Browse nested folders in a sidebar.
- Generate in-memory thumbnails for supported RAW files, including Sony ARW and DNG, as well as JPEG, TIFF, and PNG files.
- Open a zoom overlay with keyboard navigation, pan, and magnification controls.
- Copy selected original files with **Edit > Copy** or **⌘C**, then paste them into a Finder folder with **⌘V**. Grid view copies all selected files; zoom view copies the displayed file.
- Display available EXIF details such as camera, lens, exposure, ISO, dimensions, and focus point.
- Prefer matching `.jpg` sidecars for RAW full preview images when present.
- Download DataComp CLIP before enabling indexing or search.
- Download Meta SAM 3 for Deep Review.
- Select an indexed image and use **Find Similar** to rank its nearest visual neighbors.
- Recursively and incrementally index a selected folder into its hidden `.clipbench` directory.
- Search locally with natural-language descriptions and show thumbnail/path results.
- Adjust the semantic result limit in steps of ten (default 50, range 10–500).
- Enrich SAM 3 Deep Review with CLIP subject labels, EXIF autofocus points, and a whole-frame sharpness score.
- Choose Automatic, Fast, or Full scope when running SAM 3 Deep Review over a selection.

## AI models and settings

Open **RawBrowse > Settings > AI Models** to check model availability and open **Download AI Models**. CLIP and SAM 3 download from [rsyncOSX/AI-models](https://github.com/rsyncOSX/AI-models), using `manifest.json` on the `main` branch. The repository and manifest are pending publication; the app reports this clearly until they are available.

Downloaded models are stored under `Application Support/RawBrowse/AI-models/clip-datacomp` and `sam3`. Each file is checked against its manifest byte count and SHA-256 before installation. SAM 3 requires acceptance of the bundled SAM licence. Downloads support progress, cancellation, retry, removal, and Show in Finder. See [model publishing instructions](ModelAssets/README.md).

The AI workspace offers CLIP semantic search and Find Similar, plus SAM 3 Subject Detail review. The semantic result limit is available in AI Models settings.

**CLIP Indexes** manages catalog indexes; **Memory** and **Cache** configure image memory and disk caching.

## CLIP workflow

1. Open **RawBrowse > Settings > AI Models**.
2. Download DataComp CLIP, or open **Manual AI** and choose **Select CLIP Model** to use a compatible local Core AI bundle. A manually selected bundle overrides the downloaded model until the selection is cleared.
3. Wait for the model to report a valid verification status.
4. Select the folder that should become the recursive index root.
5. Choose **Index Selected Folder** in the main toolbar. Indexing never starts automatically.
6. Enter a description in the semantic search field and press Return or Search.
7. Double-click a result to inspect its full embedded/rendered JPEG with EXIF information and histogram.

RawBrowse stores one model-specific index at `.clipbench/clip-<model-hash>.clipindex` inside the selected root. Source photographs are not modified. Model inference, embeddings, and search stay on the Mac.

## Privacy Policy

Effective date: October 1, 2026.

RawBrowse processes your photographs on your Mac. The app does not collect or transmit your photographs, image metadata, search queries, prompts, embeddings, or AI assessments to the developer. It does not include advertising, tracking, or analytics services, and does not require an account.

### Local access and storage

The app accesses folders and files you select through macOS permissions. It reads photographs and their metadata to provide previews, search, and local AI analysis. CLIP and SAM 3 model inference runs locally; photographs and prompts are not uploaded for AI processing.

App settings, remembered folder access, image caches, and downloaded models are stored locally. Semantic indexes are stored in the hidden `.clipbench` directory inside the folder you index and may contain image paths and embeddings. If you run Semantic Test, its report is saved in that folder and includes queries and result paths. These files remain until you remove them or use the applicable cleanup controls.

You can clear image caches in **Settings > Cache**, remove managed models through **Download AI Models**, and delete `.clipbench` directories and semantic test reports in Finder. Removing the app does not automatically remove indexes or reports from your photo folders. You control any copying, backup, or synchronization of those folders through other software.

### Downloads and external links

Optional AI models are downloaded from GitHub, subject to its [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement). Model downloads do not upload photographs or prompts.

If you open an external model card, licence, or other website link, your browser connects to that website, whose privacy policy applies.

### Contact and changes

For privacy questions, contact the developer through the [RawBrowse issue tracker](https://github.com/rsyncOSX/RawBrowse/issues). Issues are public; do not include private photographs or other sensitive information. Any information you choose to submit there is handled by GitHub under its [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement).

This policy will be updated if the app's privacy practices change, with the effective date revised above.

## Swift package dependencies

Requirements are pinned to exact versions or revisions in the Xcode project and recorded in `RawBrowse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Revision-pinned dependencies are shown with their complete commit.

| Package (resolved identity) | Resolved pin | Responsibility | Main APIs/products used by RawBrowse |
|---|---:|---|---|
| [PhotoAIKit](https://github.com/rsyncOSX/PhotoAIKit) (`photoaikit`) | revision `77cc1d84a5d98a485caa15be102c8a55eb3d7698` | Core AI model discovery and validation, CLIP inference, embedding artifacts, multi-object SAM 3 masks, and AI workflow contracts | `CoreAICLIPProvider`, `CoreAISAM3Provider`, `PhotoAIContracts`, `PhotoAIWorkflows` |
| [RawParserKit](https://github.com/rsyncOSX/RawParserKit) (`rawparserkit`) | `1.3.1` | RAW metadata, embedded previews, thumbnails, focus-point metadata, and supported-format handling, including Sony ARW and DNG | `RawImageLoader`, `BrowserExifInfo`, `RawFocusPoint` |
| [RawCullCore](https://github.com/rsyncOSX/RawCullCore) (`rawcullcore`) | `1.1.2` | Shared image-analysis utilities | `HistogramCalculator.normalizedLuminanceHistogram` |

The Xcode target also links PhotoAIKit's `CoreAIEfficientSAMBackend`, `CoreAISAM3Backend`, `PhotoAIStorage`, and `VisionFeaturePrintBackend` products. Deep Review uses the SAM 3 backend's composited semantic mask, which includes every object matching the selected prompt.

Resolved transitive dependencies are recorded here as build inputs even though RawBrowse does not import their products directly:

| Resolved identity | Resolved pin | Role in the package graph |
|---|---:|---|
| `coreai-models` | revision `475c585fdb0fe82a83c8f777f259e9414bd44c98` | Apple Core AI model and conversion support reached through PhotoAIKit |
| `eventsource` | `1.5.1` | Server-sent-event transport used by transitive model tooling |
| `swift-asn1` | `1.7.2` | ASN.1 support reached through the cryptography stack |
| `swift-collections` | `1.6.0` | Collection data structures used by transitive packages |
| `swift-crypto` | `4.5.2` | Cryptographic primitives used by transitive packages |
| `swift-huggingface` | `0.10.1` | Hugging Face model download and metadata support used by model tooling |
| `swift-jinja` | `2.5.1` | Prompt-template rendering used by model tooling |
| `swift-transformers` | `1.3.4` | Tokenizer and transformer support used by the AI package graph |
| `xgrammar` | `0.2.2` | Grammar-constrained generation support used by Core AI language models |
| `yyjson` | `0.12.0` | C JSON engine used by transitive model tooling |

## Development

Open the project in Xcode:

```sh
open RawBrowse.xcodeproj
```

Build from the command line:

```sh
xcodebuild -project RawBrowse.xcodeproj -scheme RawBrowse -destination 'platform=macOS' build
```

Create a Release archive and a signed app for local testing:

```sh
make archive
open build/RawBrowse.app
```

The archive is written to `build/RawBrowse.xcarchive`. Its development-signed app is copied to `build/RawBrowse.app`; this target does not export an App Store installer or notarize the app.

Create a local debug archive:

```sh
make debug
```

Run the test suite:

```sh
make test-full
```

### GitHub distribution

RawBrowse is intended for GitHub distribution. Use Developer ID signing and notarization for downloadable releases. `make build` provides the existing archive, signature verification, notarization, and DMG workflow; configure your signing identities and notary credentials before running it.

AI model publication is separate from app releases. No model binaries are checked in. Historical App Store upload records in `Docs/releaseprocedure.md` do not configure or enable the GitHub downloader.

## Project Layout

- `RawBrowse/` — SwiftUI app source and bundled verified licence texts in `Resources/`.
- `RawBrowseTests/` — Browser, AI feature, download catalog, and licence acceptance tests.
- `RawBrowse.xcodeproj/` — Xcode project, schemes, and Swift package resolution files.
- `RawBrowse-Info.plist` — App metadata.
- `RawBrowse.entitlements` — App sandbox, user-selected file access, and outgoing model-download network access.
- `RawBrowseicon.icon/` — Icon Composer app icon bundle.
- `Assets.xcassets/` — Shared asset catalog.
- `ModelAssets/` — Pack manifest template, notices, historical provenance, and release setup instructions.
- `Makefile` — Build, test, archive, and export automation.
- `exportOptionsAppStore.plist` and `exportOptions.plist` — App Store Connect archive export settings.
- `exportOptionsDebug.plist` — Local debug archive export settings.
