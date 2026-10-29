# RawBrowse phases 0–2 evaluation

29 October 2026. Decision: retain diagnostic tooling and workload manifest; defer production progress coalescing. The initial evaluation changed no application source. The follow-up below implements download progress correctness guards; no loading-speed or smoother-frame improvement is claimed.

## Evidence identity

Source: `828c40c91b6e5a07c58b219e14294baaf99c9762`; worktree was clean before this investigation. Additions are this report, the linked evidence, the measurement script and updates.md. Xcode 27.1 (27A9275); macOS 27.2 (26B123). Project uses Swift 6, complete strict concurrency, MainActor default isolation and approachable concurrency. The standalone production-delegate diagnostic uses Swift 6 and `-O`; it is not the Release application executable.

Resolved dependencies remain pinned by `RawBrowse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: RawParserKit 1.3.2 (`07801a34a82d7720d301a80724c36a5b8c9f1d6c`), PhotoAIKit 1.0.0 (`4b85056e6c2603b5e382987710ca2f16f4c5c155`), RawCullCore 1.1.2 (`d25a51e65ad32a82bf82f86fa0ec07d6e14498e9`). Other dependencies are recorded in that resolved file. No package update was attempted.

## Phase 0: useful start, full baseline still pending

[Workload manifest](workload-manifest.json) records every immediate file name, size and nanosecond modification time in the user-supplied folder. It contains 574 ARW files, 51,761,762,304 bytes (48.21 GiB). The source catalog was read only; no source image was modified, copied or decoded.

Three Python enumerate/stat/sort trials: **3.508, 3.041, 3.044 ms**; median **3.044 ms**, range **3.041–3.508 ms**. These are filesystem metadata measurements, not production discovery latency. OS and storage caches were not flushed. The path alone does not establish physical storage topology.

Recommendations:

- Keep this folder as the large RAW workload. Add a small everyday workload and a genuinely mixed RAW/JPEG workload before generalizing results; this folder cannot establish JPEG behavior.
- Make phase 0 staged: progress-only tests need source/delegate identity and a controlled stream, while browsing comparisons additionally need the complete application identity, binary UUID/dSYM, settings, cache procedure and fixed action sequence. Avoid delaying a local progress diagnostic until all browsing instrumentation exists.
- For the application baseline, record thumbnail and preview caches separately, selected CLIP backend/model and pending inference count. Use a disposable isolated cache rather than clearing the user's normal cache. Define viewport dimensions, grid size, sort order, selected file and action timestamps.
- Capture discovery, first image delivery, first painted viewport and selected preview as distinct events. Use three trials initially, expand if ranges overlap. Include main-thread/UI work, hitches, peak memory and pending tasks before asserting a user-visible benefit.

Full application timings, cache experiments, executable identity and profiler captures were not collected. Phase 0 is **partial**, not passed.

## Phase 1: download fan-out confirmed; UI cost unresolved

Run `python3 Scripts/measure-progress-pressure.py` to compile the actual `GitHubModelDownloadProgress` declaration extracted from production source. The script does not maintain a second delegate implementation. [Raw results](progress-pressure-results.json) include the extracted declaration's SHA-256. Each burst is submitted synchronously while MainActor is occupied; all deliveries are then awaited through an AsyncStream. This deliberately creates backlog. The closure counts deliveries only; it does not mutate ModelDownloadsModel or render SwiftUI.

| Callbacks / MainActor tasks / deliveries | Trial 1 ms | Trial 2 ms | Trial 3 ms | Median ms | Range ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 / 100 / 100 | 0.273 | 0.113 | 0.099 | 0.113 | 0.099–0.273 |
| 1,000 / 1,000 / 1,000 | 0.987 | 0.836 | 0.807 | 0.836 | 0.807–0.987 |
| 10,000 / 10,000 / 10,000 | 7.668 | 5.586 | 4.889 | 5.586 | 4.889–7.668 |

Task counts follow directly from the production callback's unconditional `Task { @MainActor ... }`, rather than task-profiler instrumentation. Timing includes submission and delivery drain, not just MainActor CPU. Every trial delivered final fraction 1.0 and observed zero regressions in its ordered input. This does not guarantee ordering under all real callback/lifecycle interleavings. No timer or UI update counts were measured.

The existing `python3 Scripts/test-model-download-progress.py` also passed: **21 progress callbacks**, complete 1 MiB file with exact content, and cancellation after intermediate progress. Its fixture sends 64 chunks with 30 ms delays; server writes are not identical to URLSession callback events. This single integration run is not a fast/slow transfer distribution. It required running outside the filesystem sandbox to bind a loopback port.

Coverage review:

- GitHubAIModelDownloadTests covers manifest safety, size/checksum verification, disabled service behavior, prior-file byte offsets and cancellation before network start.
- AIModelDownloadTests covers licence/coordinator behavior, late cancellation reconciliation, independent model progress and removal ownership.
- The loopback script exercises the production network delegate and temporary-file preservation, not observable publication or actual UI.
- The new diagnostic isolates callback-to-MainActor fan-out. It does not establish accepted observable-write counts, UI invalidations or hitch cost.

### Lifecycle findings

`ModelDownloadsModel.performCLIPModelDownload` rejects callbacks unless the state is downloading and the currently stored task is not cancelled. This correctly rejects progress while validating, failed, available or shutting down through task cancellation. However, the closure captures only model identity. An old callback executing after a replacement attempt starts would see the replacement's downloading state and uncancelled task. `Task.isCancelled` inside the delegate-created unstructured task does not identify the original download worker's cancellation. **The guard is insufficient for that interleaving; its occurrence in a real transfer was not reproduced.** Existing worker ownership prevents immediate overlapping attempts until the worker exits, which narrows the window but does not give already queued closures an attempt identity.

The service emits byte fractions per delegate plus an awaited exact aggregate fraction after each verified/moved file. Delayed earlier callbacks can in principle regress a later aggregate value. Clamping to 0...1 does not ensure monotonicity. This ordered synthetic input did not reproduce a regression. Keep byte validation/installation independent of displayed progress; 1.0 received bytes does not mean the model is available. Current `.validating` is assigned after the service has already verified and installed files; don't describe it as a measured verification-stage interval.

### CLIP assessment

CLIPSearchEngine passes only pending sources to SimilarityArtifactIndexer, so callback totals describe pending work, not the full discovered folder. It awaits the progress closure; CLIPFeatureModel validates indexingID and owned-task cancellation before assigning progress. This differs from unconditional unstructured download task creation. Both pending and empty-work paths save the index before returning success. Empty work has no indexer callbacks. Keep existing cancellation/worker ownership and persistence semantics.

No fresh/partial-reuse inference run or callback frequency measurement was performed. There is no measured basis for CLIP coalescing. Phase 1 is **partial**: controlled download pressure measured; representative downloads, accepted writes/UI cost and CLIP cadence remain pending.

## Phase 2: defer optimization; prioritize a small correctness change

The measurements show linear task fan-out, but even the artificial 10,000-event burst drained in milliseconds with a trivial consumer. They do not establish material application overhead. A 100 ms coalescer could reduce publication, but adds delayed delivery, cross-thread state and invalidation responsibilities. Production adoption is not justified by callback count alone.

Recommended order:

1. Add per-attempt identity to progress acceptance, with deterministic tests that hold an old callback until a retry is active, then release it. Test cancellation, failure, successful availability and shutdown similarly. This is a correctness recommendation independent of any speed claim.
2. Measure callback arrival, MainActor delivery latency, accepted writes and UI updates during representative transfers, including a fast local fixture. Distinguish current network cadence from the diagnostic's artificial backlog.
3. Only if that establishes excessive presentation work, compare unchanged delivery, publication-only coalescing and pre-MainActor coalescing. Publication-only coalescing retains the measured task fan-out. A pre-hop candidate needs synchronized latest state, one scheduled tick per attempt and an attempt/sequence check at final delivery; do not hold a lock while calling progress.
4. Preserve immediate initial/terminal state, invalidate pending ticks on every terminal path, suppress duplicates and regressions within an attempt, and scope aggregation across all files rather than resetting at each per-file delegate. A callback-triggered fixed tick must not become a debounce that can postpone delivery indefinitely.
5. Use an injectable scheduler to cover bursts, duplicate/out-of-order snapshots, file boundaries, completion before tick, stale timers, retry, two simultaneous models and owner release. Compare repeated controlled runs, then real integration and matched UI captures.

No executable coalescing candidate or before/after performance comparison was run. Phase 2 is **evaluated with deferral**, not implementation accepted. Do not mark full candidate acceptance complete. Keep RawCull's coalescer as a lifecycle reference only; its workload-wide preload benefit does not transfer automatically to occasional model downloads.

## Validation and limits

The optimized diagnostic completed all nine trials; the existing loopback integrity/cancellation check passed. During the initial evaluation no application build or full suite was run because application source was unchanged; follow-up application validation is recorded below. The script generates temporary binaries and module caches and removes them after each invocation. Evidence JSON and the manifest are retained beside this report; no large trace archive is needed for these measurements.

The initial recommendation was narrowly scoped attempt identity with meaningful lifecycle tests (implemented in the follow-up below), followed by instrumented transfer measurements. Browsing/cache rewrites and CLIP throttling remain unsupported by this investigation.

## Follow-up implementation — 29 October 2026

Applied the recommended correctness change in ModelDownloadsModel. Each worker has a UUID scoped to its model; the progress closure must match that UUID as well as the active downloading state and uncancelled owned task. Cancellation and shutdown immediately invalidate acceptance. Success and failure invalidate it before terminal reconciliation; worker cleanup also removes the identity. Worker ownership remains held until exit, including cancellation reconciliation. No timer, delegate lock, byte-accounting change or CLIP change was introduced.

Displayed progress takes the maximum of its current and newly clamped fraction within an attempt, preventing a delayed earlier file update from moving the display backward. A new attempt starts at zero. This does not infer installation from the fraction or reduce callback task creation.

Added a parameterized regression test in AIModelDownloadTests that retains the actual model progress closure beyond worker exit. Four controlled scenarios cover success/installed state, failure, cancellation and shutdown, then release old callbacks during a replacement attempt. The same cases verify out-of-order progress and continued acceptance of the new attempt's updates. Continuations/streams control ordering; there are no timing sleeps.

Focused Xcode tests (AIModelDownloadTests, GitHubAIModelDownloadTests and FeatureOwnershipTests) passed, followed by the full macOS suite. The isolated production-model check with stubbed coordinator dependencies passed all four cases before the full Xcode run; this is supplementary and does not replace application integration tests. The initial Xcode run failed during dependency fetching after a connection reset; it was restarted after network recovery.

Application validation commands (all use `-onlyUsePackageVersionsFromResolvedFile`):

- Focused: `xcodebuild test -project RawBrowse.xcodeproj -scheme RawBrowse -destination 'platform=macOS,arch=arm64' -onlyUsePackageVersionsFromResolvedFile -only-testing:RawBrowseTests/AIModelDownloadTests -only-testing:RawBrowseTests/GitHubAIModelDownloadTests -only-testing:RawBrowseTests/FeatureOwnershipTests`
- Full suite: `xcodebuild test -project RawBrowse.xcodeproj -scheme RawBrowse -destination 'platform=macOS,arch=arm64' -onlyUsePackageVersionsFromResolvedFile`
- Release: the local Release build command in updates.md. **BUILD SUCCEEDED**.

Transient command logs: `/tmp/rawbrowse-download-tests.log`, `/tmp/rawbrowse-full-tests.log` and `/tmp/rawbrowse-release-build.log`. These are local diagnostics, not durable evidence archives. Test result bundles are managed by Xcode in DerivedData.

Final follow-up result: focused tests, full suite, local Release build and `git diff --check` passed. Progress coalescing remains deferred; phase 0/1 application measurements remain partial. This correctness change makes no performance-gain claim.
