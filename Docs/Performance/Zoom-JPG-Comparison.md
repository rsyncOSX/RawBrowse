# Zoom JPG browsing comparison

29 October 2026. Initial source investigation at RawBrowse `c1badc1`; compared with the adjacent RawCull checkout. Findings below describe that baseline. The subsequent implementation and validation are recorded at the end. Both projects resolve RawParserKit 1.3.3 at `26df4abc2178d5c07d08f3883d84d0648f5141d3`.

“JPG” can mean a standalone JPEG file or the JPG preview of a RAW file. These follow different paths; the strongest app-to-app difference below affects RAW files in JPG mode.

## Findings

### RAW decoder and sidecar work blocks RawBrowse's JPG cache lookup

`ZoomModel.openZoom` awaits `RAW9Support.isSupported`, and then `raw9.restore` when supported, before deciding whether to develop RAW or request the JPG preview. The capability check constructs a `CIRAWFilter`. Restoration can also wait for a pending sidecar save. This happens in JPG mode as well as developed RAW mode. The overlay separately performs another capability check for the selected file.

RawCull's `ZoomPreviewHandler` selects the JPG path directly and invokes `FullSizePreviewLoader`, which checks a sibling JPEG and then the disk cache. RAW decoder support and adjustment restoration are not prerequisites for this path.

This is a confirmed unnecessary dependency before a possible warm-cache hit, and the first candidate to measure/fix. Its contribution to the user's observed delay has not been timed. Standalone JPEGs are explicitly excluded from the decoder probe, so they do not incur CIRAWFilter construction or restoration.

### Completed Zoom JPG previews are not retained in RawBrowse memory

`BrowserImageLoader.extractedJPGTasks` deduplicates concurrent requests only. Entries are removed after completion. `MemoryImageCache` stores thumbnails only. `memoryCacheSizeMB` and `maxCachedExtractedJPGs` are decoded and logged, but do not configure a Zoom JPG memory cache.

Revisiting a RAW preview reads the JPEG disk cache again. Revisiting a standalone JPEG reloads the original file; rendered images intentionally bypass the full-size disk cache. Duplicating the original JPEG on disk would not eliminate decoding, so a disk-cache bypass alone is not a defect.

RawCull's full-size JPG loader also lacks a completed-preview memory cache. Its separate thumbnail source does use the thumbnail cache. Missing preview retention is an improvement opportunity, not by itself an explanation for RawCull being faster in the same full-size source mode.

### RawBrowse adds a full-resolution-then-resize stage

`BrowserImageLoader.previewImage` obtains the full-size image, then redraws it into a high-quality CGContext if its longest edge exceeds `thumbnailSizeFullSize` (default 8700). RawCull's embedded JPG handler displays the loaded image without this resize stage.

For large or rotated images, RawBrowse can perform full-size orientation normalization followed by another bitmap allocation/redraw. The resize is skipped for images at or below the limit. A target-size ImageIO decode could avoid some work for standalone JPEGs, but must preserve image quality, orientation, color, and zoom semantics. Smaller display dimensions must not silently replace the resolution needed for pixel inspection.

### Rapid navigation leaves obsolete loader work running

Cancelling `ZoomModel.zoomTask` rejects stale delivery, but does not cancel the independent full-size loader task or its detached rendered-image load. Requests for different images can accumulate, and RAW misses can continue through extraction/persistence after the user navigates away. There is no app-level admission limit for standalone JPEG preview loads. RawParserKit separately bounds its RAW preview work.

This needs a rapid-navigation workload before changing ownership: cancellation of one waiter must not invalidate another waiter, and cache clearing must still drain owned work. RawCull also has imperfect cancellation of detached work, so this is not established as a unique regression.

## Other comparison details

- Both full-size RAW preview miss paths wait for cache persistence before returning the image. Persistence-before-display is therefore not unique to RawBrowse.
- RawCull checks for a sibling `.jpg` before its disk cache. RawBrowse checks its disk cache first and reaches RawParserKit's sibling-JPEG preference on a miss. Folders containing developed sibling JPEGs can therefore use different source/lookup paths.
- The shared orientation loader can return a deferred image for orientation 1. Neither app's use of it proves JPEG decoding is completed off the main thread. Model-delivery timings alone cannot establish painted-frame latency.
- Existing Phase 4 reports concentrate on ARW grid loading and a few preview openings, not matched sequential Zoom navigation in the two apps. They do not validate this reported interaction.

## Recommended order

1. Remove RAW decoder/sidecar prerequisites from JPG image delivery while preserving adjustment restoration for editing and developed RAW mode.
2. Add stage timing for capability probing, sidecar restoration, original-JPEG loading, and actual display/decode work. Current diagnostics do not isolate all these stages.
3. Compare both apps in Release using identical files and full-size JPG source: sequential next, previous/revisit, and rapid navigation; distinguish standalone JPEGs from RAW embedded previews, and cold application disk cache from warm disk and memory revisits.
4. Evaluate a byte- and count-bounded preview memory cache using source fingerprints and requested size, with cache-clear/settings integration. Then evaluate direct target-size decoding where resizing is actually exercised.

## Validation limits

The initial investigation followed the checked-in source and dependency pins; it was not a timed comparison of running applications. The previous `/Volumes/MacMini4/...` photo workloads are unavailable on this host, and no JPEG/ARW fixtures were found in the two searched RawBrowse/RawParserKit workspaces. The implementation tests below generate disposable fixtures instead.

## Applied changes

- JPG mode now delivers the preview and EXIF/focus metadata before probing RAW decoder support and restoring editing adjustments. Developed RAW mode still restores adjustments before rendering. Standalone rendered images skip deferred RAW setup entirely.
- Completed JPG display images are retained in a loader-owned LRU memory cache. Keys combine the existing source fingerprint and requested maximum pixel size. The existing `memoryCacheSizeMB` and `maxCachedExtractedJPGs` settings now control retention, including disabling it with zero. Defaults cap retention at 768 MiB and four images; oversized entries are skipped.
- Settings persistence applies cache configuration, and Zoom applies its current snapshot before requesting a JPG. Cache clearing removes retained previews; a generation check prevents an older suspended preview request from repopulating the cleared cache.
- Added opt-in `preview.memoryHit`, `preview.originalImage`, `preview.raw9Support`, and `preview.raw9Sidecar` diagnostics.
- Kept resolution, orientation, resize/decode behavior, disk formats, dependencies, and shared-request cancellation ownership unchanged. Direct target-size decoding and admission/cancellation redesign remain separate profiling candidates.

### Validation

The focused JPEG cache suite passed, then the full macOS suite passed: 153 test functions, 220 runs including parameterized cases, zero failures or skips. Tests cover final-image identity on revisits, standalone JPEG orientation, source/size invalidation, count/byte limits, disabled retention, and JPG/metadata delivery while RAW support and sidecar restoration are explicitly blocked. Closing Zoom during restoration rejects stale state. Existing shared-loader cancellation, disk-cache isolation, sidecar persistence, export, and navigation tests also pass.

The optimized Release build succeeded and `git diff --check` passed. Test result: `/tmp/rawbrowse-zoom-validation/Logs/Test/Test-RawBrowse-2026.10.29_15-07-40-+0100.xcresult`. Build: `/tmp/rawbrowse-zoom-validation/Build/Products/Release/RawBrowse.app`. These are transient local artifacts. Existing sendable-capture warnings in unrelated settings tests remain; no new warning was reported for the changed production files.

No source photos or dependencies were edited, and application cache directories were not manually cleared. No timed improvement or first-painted-frame claim is made; matched photo browsing in both apps remains the next performance validation.

## Follow-up: RAW 9 work overlapping JPG browsing

Source review on 29 October found a second path in `BrowserZoomOverlayView`: its selection task independently checked RAW 9 support, then read camera white balance and tone defaults even in JPG mode. Those three operations each constructed a `CIRAWFilter`. Together with the model's deferred support check, a compatible selection could construct four filters. These are decoder setup/default reads, not an explicit full RAW render, but the overlay work could overlap JPG loading. The existing `preview.raw9Support` interval covered only the model's probe.

The follow-up change makes `ZoomModel` own the current file's support result. The overlay reuses that result and loads white balance/tone defaults only when developed RAW is selected. The result is published after sidecar restoration and cleared on navigation/close; cancelled setup cannot publish stale support. JPG mode therefore retains one support probe after image and metadata delivery, with no overlay decoder/default reads. Folder compatibility scans remain independent background work.

Validation extends the JPG delivery regression to check that support remains unavailable during blocked probing/restoration and after closing. Actual photo browsing and first-painted-frame timings still require a matched runtime workload; filter-count reduction alone is not a measured latency improvement.

The full macOS test suite passed after this change (`xcodebuild test`, arm64, existing pinned dependencies); `git diff --check` passed. Existing sendable-capture warnings remain in unrelated tests. Test log: `/tmp/rawbrowse-raw9-browsing-tests.log`.
