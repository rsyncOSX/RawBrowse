# RawBrowse performance updates and investigation plan

Prepared 24 October 2026. Evaluated 29 October 2026: phases 0–2 reviewed with a workload manifest, optimized production-delegate pressure measurements and a loopback integrity/cancellation check. Follow-up implementation adds download-attempt identity and monotonic displayed progress. See [the phase 0–2 evaluation](Docs/Performance/Phases0-2-Evaluation.md) for results and recommendations.

Current decision: phase 0 and phase 1 remain partial; phase 2 production coalescing is deferred because material UI overhead has not been established. Per-download-attempt progress identity and monotonic displayed progress are implemented as correctness improvements. Measure representative transfer/UI pressure before adding a timer. CLIP coalescing remains deferred pending inference measurements. Follow-up validation passed: focused download/ownership tests, full macOS test suite and local Release build.


Phase 4 exploratory baseline (29 October): [browsing baseline report](Docs/Performance/Phase4-Browsing-Baseline.md), [two-workload manifest](Docs/Performance/Phase4-Workloads.json), and [six paired-trial summaries](Docs/Performance/Phase4-Baseline-Results.json). Three empty-cache/fresh-process warm-disk pairs show that the thumbnail parser round trip dominates empty-cache request time for the fixed initial filename cohort. Warm-disk trials avoid parser calls. Two Blank + Time Profiler-only captures saved and exported successfully; the standard template pilot failed with a logging-stream error and was discarded. Retained changes are opt-in stage timing and disposable cache roots, not a performance optimization. Full tests and diagnostic Release build passed. Phase 3 is explicitly deferred; phase 4 remains partial pending parser isolation, painted-frame readiness, complete settings identity and broader interaction measurements. Next: isolate parser queueing versus decode/file-access work using the pinned dependency.

Parser follow-up: [round-trip investigation](Docs/Performance/Phase4-Parser-Investigation.md) and [36-trial results](Docs/Performance/Phase4-Parser-Results.json) reproduce increasing request latency with similar batch throughput. A temporary instrumented dependency copy observes serialized work and substantial waiting before it; all 82 files have identical output pixels across variants. No application or dependency change is retained. Next experiment: concurrent-executor placement with the existing six-slot bound, first in temporary sources.

Executor candidate: [standalone experiment](Docs/Performance/Phase4-Executor-Candidate.md) shows lower batch latency when a temporary parser helper explicitly uses the concurrent executor while preserving six slots. All 54 runs completed with matching pixels; the temporary uninstrumented package passed 105 tests. Candidate CPU and memory usage increase. A review patch is retained as experiment evidence only; no dependency change is adopted. Next: paired sandboxed app copies with matching diagnostics and settings.

## Purpose

Determine which lessons from RawCull's performance phases 0–6 apply to RawBrowse. Establish a RawBrowse baseline, test individual candidates, and retain only changes supported by measurements and lifecycle checks.

RawCull retained observable progress coalescing and simpler progress animation. Its JPEG encoding, grid preparation, source latency and interactive UI investigations did not justify further production optimizations. Reduced sampled main-thread work did not establish repeatably faster loading or fewer hitches. RawCull's results are context, not RawBrowse measurements or promised gains.

Reference: `../RawCull/Docs/phase0to6.md` and the individual `PerformancePhase2.md` through `PerformancePhase6.md` reports.

## Current architecture

| Area | Source under RawBrowse/ | Finding and implication |
| --- | --- | --- |
| Folder discovery | `Features/Browser/BrowserContentsModel.swift`; `Infrastructure/ImageLoading/BrowserImageLoader.swift` | Folder and file discovery run concurrently, then publish discovered files as an array. No per-file catalog progress publisher equivalent to RawCull's preload publisher was found. |
| Grid thumbnails | `Features/Browser/Grid/BrowserThumbnailCell.swift`; `ThumbnailPresentationModel.swift`; `Infrastructure/ImageLoading/BrowserImageLoader.swift` | Cells request images on demand. The loader checks memory/disk caches and shares tasks by URL and pixel size. Catalog-wide preload coalescing has no direct counterpart. |
| CLIP indexing | `Features/CLIP/CLIPSearchEngine.swift`; `CLIPFeatureModel.swift` | Indexer callbacks directly publish observable progress after operation/cancellation checks. Measure callback pressure before changing this. |
| Model downloads | `Features/ModelDownloads/CLIPManagedModels.swift`; `ModelDownloadsModel.swift` | Each byte-progress callback schedules a MainActor task; accepted values update observable download state. Strongest initial coalescing candidate. |
| Progress UI | `Features/ModelDownloads/Views/CLIPModelDownloadsView.swift`; `Features/Settings/Views/CLIPIndexesSettingsTab.swift`; browser sidebar | Standard progress views/text. No equivalent of RawCull's spring-animated progress ring or numeric transition was found. |
| JPEG cache | `Infrastructure/ImageLoading/ThumbnailDiskCache.swift` | Uses JPEG quality 0.7. RawCull did not establish a useful encoder-options reuse optimization. |

These findings come from source inspection. Runtime costs remain unmeasured.

## Phase 0 — Create a reproducible baseline

Record source revision and dirty diff, Xcode/macOS versions, resolved dependencies, Release settings, executable path, binary UUID and matching dSYMs. Verify the measured process is that executable.

Choose a large RAW folder, a smaller everyday folder and a mixed RAW/JPEG folder. Record names, sizes, modification times, count, formats, total bytes, storage location and thumbnail/preview settings. Keep the same inputs for comparisons.

Define cache conditions separately:

- Empty thumbnail disk cache.
- Warm disk cache with a fresh app process.
- Warm in-process memory cache.
- Full-size preview cache state, independently of thumbnail state.
- CLIP index absent, fully reusable, or partially invalidated; record model/backend and pending inference count.

An empty thumbnail cache does not imply cold OS/storage/parser caches. Record rather than hide that limitation.

For each condition run at least three comparable trials, report individual values, median and range, and increase repetitions when variation obscures results. Interleave baseline/candidate runs where practical.

Measure folder discovery, file-list publication, first visible thumbnail, visible viewport readiness and selected preview readiness. Record main-thread sampled work, SwiftUI updates where available, hitches, peak memory and task buildup. Distinguish image readiness from the first painted frame, sample counts from actual view executions, and benchmark timings from instrumented app timings.

Deliverable: baseline report, workload manifest, fixed action sequence, cache procedure, build identity and evidence locations.

## Phase 1 — Measure progress publication pressure

### Downloads: highest priority

Inspect `GitHubModelDownloadProgress.urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)` in `CLIPManagedModels.swift` and the progress closure in `ModelDownloadsModel.performCLIPModelDownload`.

Investigate:

1. Callback frequency and burst size on fast and slow transfers.
2. Raw callback count, MainActor task count, accepted observable writes and actual UI updates as separate metrics.
3. Delay between callback arrival and publication, duplicate values and queued out-of-order values.
4. Callbacks arriving after cancellation, validation, failure or retry of the same model.
5. Whether current guards distinguish an old attempt from a replacement attempt. This is a question to verify, not an established bug.
6. Independence of simultaneous model downloads.
7. Aggregate progress across multiple files and monotonicity at file boundaries.

Use controlled callback streams or a local fixture to isolate publication overhead. Real download elapsed time depends on network/server behavior and is not a reliable isolated measure of UI optimization. Use real downloads for integration checks.

Review `RawBrowseTests/AIModelDownloadTests.swift`, `GitHubAIModelDownloadTests.swift` and `Scripts/test-model-download-progress.py` before extending coverage; identify the layer each exercises.

### CLIP indexing: secondary priority

Inspect `CLIPSearchEngine.synchronize`, the artifact indexer callback, and `CLIPFeatureModel.publishIndexingProgress`.

Measure fresh indexing and partial reuse separately, under fast and slow inference. Determine whether callback frequency is high enough to create material UI work. Confirm whether completed/total refer to pending entries or the entire folder, and establish empty-work, persistence, failure and completion semantics.

Preserve current operation identity and cancellation guards. `cancelIndexing()` keeps worker ownership until the worker exits, including non-cooperative inference; progress changes must preserve that behavior.

Exit criterion: proceed only where callback pressure produces measurable unnecessary work or a demonstrated UI problem. Low-frequency inference progress may need no change.

## Phase 2 — Evaluate download progress coalescing

Conditional implementation after measurement; this document does not implement it.

Use RawCull's `CatalogProgressCoalescer.swift` as a behavioral reference. Do not copy catalog-specific counts or ETA into downloads.

Candidate contract:

- Start with approximately 100 ms between intermediate publications, then assess responsiveness and cost.
- Keep the latest snapshot and one scheduled delivery per active attempt. New callbacks replace the snapshot without continually postponing the scheduled tick.
- Suppress duplicates and keep aggregate progress monotonic within an attempt.
- Publish initial state and terminal transitions immediately. Completion, validation, availability and errors must not wait for a timer.
- Invalidate pending delivery on cancellation, failure, replacement, suspension and shutdown.
- Use attempt identity where required; model identity alone may not distinguish retries.
- Reject stale callbacks and already queued timers after invalidation. Avoid retained models/delegates from pending delivery.
- Keep exact byte accounting and transfer lifecycle independent of presentation. Do not infer completion from the last displayed fraction.

Investigate placement carefully. Coalescing after every callback has already created a MainActor task reduces observable writes but leaves scheduling pressure. Compare publication-layer coalescing with coalescing before the MainActor hop. Choose the smallest design addressing the measured bottleneck and explicitly account for delegate-thread synchronization.

Meaningful tests should cover bursts, duplicates, out-of-order values, completion before a tick, cancellation/failure, same-model retry, late callbacks after validation/availability, independent simultaneous downloads, multi-file boundaries and owner lifetime. Prefer controlled scheduling or an injectable clock over timing-sensitive sleeps.

Compare callback/task/publication counts and main-thread work against baseline. Repeat real-download integration checks separately from controlled performance trials.

## Phase 3 — Decide whether CLIP needs coalescing

Only proceed if phase 1 shows excessive publication. Adapt the proven mechanism to existing indexing identity and ownership rather than introducing a parallel lifecycle.

Investigate filename presentation when intermediate files are intentionally skipped. Keep exact indexer accounting independent of displayed snapshots, and preserve immediate cancellation/error feedback. Pending progress must not reappear after folder/model/runtime changes or cancellation.

Respect cleanup that clears progress when the owned worker exits. Do not publish artificial successful completion before index persistence finishes. Determine whether displaying a final count is useful given immediate terminal cleanup.

Review and extend relevant scenarios in `CLIPFeatureTests.swift`, `ConcurrencyOwnershipTests.swift` and `FeatureOwnershipTests.swift`. Cover empty work, partial reuse, fast completion, delayed inference cancellation and replacement operations. Defer the change if measured benefit is negligible.

## Phase 4 — Investigate browsing and image loading separately

Consider opt-in timing/signposts for enumeration, sorting, array publication, thumbnail memory hit, disk decode, RawParserKit round trip, JPEG encoding/save, preview lookup and preview extraction/resizing.

Use a RawBrowse subsystem and unique request/operation identities. Close intervals on success, failure and cancellation. Validate nonempty exports and begin/end pairing. Adapt RawCull tooling to RawBrowse names and schemas; do not assume its configuration works unchanged. Keep verbose per-file diagnostics out of normal operation.

Questions to answer:

1. Is folder-opening latency enumeration, sorting, publication or initial layout?
2. Which thumbnail stage dominates empty-cache versus warm-cache runs?
3. Does rapid scrolling create task buildup, excessive parser concurrency, duplicate work or cache churn?
4. How does shared-task ownership behave when one cell disappears while another still needs the image? Review existing safeguards before proposing changes.
5. Does visible image delivery wait materially for disk persistence? If so, measure before considering asynchronous saves; preserve cache-clear generations and write ownership.
6. Are target sizes and cache keys stable through layout/settings changes?
7. Are preview delays cache-related, parser-related, resizing-related or presentation-related?
8. Does memory growth originate in caches, visible images, outstanding tasks or full-size previews?

Both apps use RawParserKit, but RawCull's observed long-tail round trips do not identify a RawBrowse bottleneck or its cause. If parser calls dominate, capture a minimal reproduction and exact dependency identity before changing concurrency, priority or dependencies.

Explicitly deferred pending independent evidence:

- JPEG encoder-options reuse: no useful repeatable RawCull gain.
- Direct ImageIO grid downsampling: RawCull's tested candidate was slower; RawBrowse has a different on-demand path.
- Broad cache rewrites, background disk saves and concurrency changes.
- Progress animation port: no corresponding progress animation was found. Zoom reset/gesture springs serve a different interaction and are outside this transfer.

## Phase 5 — Verify interactive behavior

Use a fixed sequence: open folder, wait for the initial viewport, scroll, select images, open/close zoom, switch folders during loading, start/cancel indexing and exercise download progress. Include relevant empty/warm-cache conditions.

Capture Time Profiler and, where collection works, SwiftUI and hitch information. If combined collection fails or loses signposts, use smaller captures and document correlation limits. Separate native file-picker waiting from app-owned work.

Repeat before/after sequences with matching workload, settings and recording windows. Check keyboard navigation, selection, sidebar response, cancellation and readable progress. Test Reduce Motion if introducing animation. Reduced CPU sampling alone does not prove fewer hitches or smoother frames.

## Validation and reporting

For future implementation, use normal build/test commands. The default Makefile target includes packaging and distribution steps and is unnecessary for this investigation.

Existing entry points are `make test-smoke` and `make test-full`. The smoke target selects `CLIPFeatureTests`, so download tests require separate selection or the full suite. Review existing coverage and add only tests of meaningful lifecycle/behavior contracts.

Local Release build:

```sh
xcodebuild -project RawBrowse.xcodeproj -scheme RawBrowse \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -onlyUsePackageVersionsFromResolvedFile build
```

Run relevant tests per implementation change, then the full suite and Release build for retained changes. No application test/build is required for this planning document alone.

Each experiment report should contain hypothesis, revision/diff, workload, cache/settings, instrumentation, individual results, correctness checks, limitations and a retain/defer/reject decision. Keep large traces outside Git, with evidence manifests and matching symbols. Separate publication reduction, sampled-work reduction, elapsed latency and visual responsiveness claims.

## Acceptance criteria and checklist

Success means less unnecessary progress publication or lower measured UI overhead without stale state, delayed completion or lifecycle regressions. A loading-speed claim requires a repeatable elapsed-time improvement. Inconclusive or negative experiments finish with documented deferral.

- [ ] Phase 0: reproducible baseline and workload manifests.
- [ ] Phase 1: download and CLIP callback pressure measured.
- [ ] Phase 2: download candidate evaluated and decision recorded.
- [x] Phase 3: explicitly deferred; inference callback pressure remains unmeasured.
- [ ] Phase 4: browsing/image stage bottlenecks measured.
- [ ] Phase 5: matched interaction checks and final comparison.
- [ ] Retained changes pass relevant lifecycle tests, full tests and Release build.
- [ ] Final report separates demonstrated gains from unresolved questions.
