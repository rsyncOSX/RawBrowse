# Phase 4 — exploratory browsing baseline

29 October 2026. Retain opt-in diagnostics and the cache comparison. Investigate the RawParserKit thumbnail round trip next; do not change parser concurrency, cache architecture, or JPEG encoding based on these results. This is a first application baseline, not completion of every phase 0/4 requirement.

## Identity and inputs

Base revision `6cd1cde736dddd087180a9ff5569d19502e13e60`, initially clean. Diagnostic source hashes and the resolved dependency hash are in [results](Phase4-Baseline-Results.json). No dependency changes. Xcode 27.1 (27A9275), macOS 27.2 (26B123), arm64 Mac mini with 16 GiB RAM. Release build uses the normal project settings and sandbox. Timing executable and matching dSYM UUID: `5C7B7484-BEF4-3B1F-9742-9EE1D918742F`.

[Workload manifest](Phase4-Workloads.json):

- Small: `/Volumes/MacMini4/Pictures_raw/2026/06_mai_2026`, 26 ARW images, 26 XMP and 26 DOP sidecars; all files total 1,468,584,068 bytes.
- Large: `/Volumes/MacMini4/Lundfug_7juli_2026/DCIM_A7R6/100MSDCF`, 574 ARW images, 51,761,762,304 bytes.

Immediate-file sizes and nanosecond modification times match the pre-run manifest after all trials. No source image edits or index operations were performed. Neither input covers JPEG browsing.

## Method and instrumentation

Application diagnostics are disabled unless `RAWBROWSE_PERFORMANCE_LOG` is set. `-` writes JSON lines to inherited stderr, which avoids widening sandbox access. An absolute path can also be used when writable by the app. Each completed interval records a UUID, source path, monotonic start/end, duration and result. The synchronous writer is protected by `Synchronization.Mutex`; it creates no per-event tasks. Timings include suspension/queueing and can overlap. `finished` denotes interval termination, not successful image presentation. Parser records separately distinguish image/failure.

`RAWBROWSE_PERFORMANCE_CACHE_ROOT` overrides only thumbnail and full-size JPEG disk-cache roots. Explicit cache URLs supplied by existing tests/callers retain priority. Normal launches use the existing cache locations. For these trials, roots were under `/Users/thomas/Library/Containers/no.blogspot.RawBrowse/Data/tmp/phase4-controlled-{1,2,3}`. Each empty-cache process had a new root; its paired fresh process reused that root. User caches were not cleared. OS/storage/parser caches were not flushed; “empty” refers only to the two application disk caches.

Three paired runs, ordered empty-1/warm-1/empty-2/warm-2/empty-3/warm-3. Each process restored the large catalog, selected the small folder, opened/closed its first-image JPG preview, returned to the large catalog, and opened/closed its first-image preview. Empty-cache processes also revisited both folders in memory. Normal shutdown followed. The restored window was unchanged during trials; its dimensions, full settings snapshot and CLIP backend were not exported. CLI tests/builds were finished before controlled timing runs. Wall time between UI commands varies and is not a loading metric.

The large catalog's initial request batch contains the first 56 sorted filenames; the small folder contains all 26. Later layout/prefetch/revisit requests can extend the large set to 112. Compare the fixed initial filename cohort, explicitly listed in the results. Every request in that cohort finished in all six runs. Empty runs 2 and 3 also contain 18 and 26 cancelled intervals outside it. This is exploratory cohort analysis, not a claim that a complete viewport or catalog was painted. The earlier plan to discard an entire interrupted run was refined after checking that the fixed initial cohort had completed independently of later cancellations.

No Instruments recording overlapped the six stage-timing trials. Opt-in JSON writing adds overhead; no matched logging-disabled timing comparison was performed.

## Thumbnail results

Values are the median individual request duration within the fixed cohort, in milliseconds. The final column is the median of the three trial medians, not a pooled sample median.

| Workload / stage | Trial 1 | Trial 2 | Trial 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Large, empty-cache request | 527.37 | 544.91 | 624.51 | 544.91 |
| Large, parser round trip | 523.95 | 541.40 | 619.73 | 541.40 |
| Large, warm-disk request | 6.02 | 4.87 | 5.75 | 5.75 |
| Small, empty-cache request | 167.72 | 338.46 | 375.06 | 338.46 |
| Small, parser round trip | 165.16 | 334.94 | 372.95 | 334.94 |
| Small, warm-disk request | 3.90 | 4.05 | 2.24 | 3.90 |

All fixed-cohort empty-cache lookups missed and produced parser images. All warm-disk lookups hit; there were no thumbnail parser calls in any warm-disk run. Empty-cache median disk lookup was 0.17–0.86 ms across workload/trial groups, and median JPEG encode plus disk save was 0.61–0.86 ms. Those stages do not explain the much longer parser round trip in these trials.

For the large initial cohort, the interval from its first thumbnail request to the first returned thumbnail was **145.22, 189.47, 113.93 ms** with empty caches and **3.68, 4.53, 4.11 ms** with warm disk caches. Its entire request window was **938.10, 869.90, 988.53 ms** empty and **6.56, 8.12, 9.66 ms** warm. Neither measurement identifies a painted frame; the request window is not the sum of overlapping request durations.

Initial large-folder discovery/publication intervals were **39.21, 28.72, 14.37 ms** in empty processes and **24.95, 28.23, 25.33 ms** in warm processes. Initial small-folder intervals were **3.06, 2.11, 2.24 ms** and **2.52, 2.67, 2.30 ms**, respectively. These include discovery and synchronous publication callbacks, excluding subsequent SwiftUI rendering. Startup and sidebar restoration differ from selecting the small folder; do not interpret the difference as a pure file-count scaling curve.

First-image full-size preview delivery (before resize/render) was 7.16–14.86 ms empty and 4.93–6.95 ms warm across the six workload/trial groups. This limited first-file exercise does not characterize all RAW previews or developed RAW mode.

Memory-cache revisits were exercised, but the presentation model can return before calling BrowserImageLoader. The new loader timings do not measure that path end to end. `/usr/bin/time -l` reported whole-process peak RSS of 2.37–4.32 GiB and peak memory footprint of 3.16–3.25 GiB. They are different OS metrics over manually paced sessions including previews and runtime startup. No cache-specific memory attribution or leak claim follows.

## Time Profiler and trace reliability

The standard **Time Profiler template** also enabled Hangs and Points of Interest. Its 15-second launch pilot reported “Fatal logging system error: The log archive is corrupt or incomplete and cannot be read.” Its process table resolved to `/Applications/RawBrowse.app`, despite the requested executable. Discard it as baseline evidence.

The working command is **Blank template plus Time Profiler only**, attaching to a verified PID:

```sh
xcrun xctrace record --instrument 'Time Profiler' --attach PID \
  --time-limit 20s --output /tmp/rawbrowse-phase4/example.trace
```

Two recordings completed successfully and exported nonempty CPU sample tables:

| Capture | Process | CPU samples | Main-thread samples |
| --- | --- | ---: | ---: |
| `attach-pilot.trace` | Release PID 2712 | 4,538 | 2,161 |
| `isolated-large.trace` | Diagnostic Release PID 3447 | 4,967 | 2,715 |

The first includes large-folder opening/scrolling; the second includes scrolling in the isolated-cache process after startup. They have different actions and builds and are **not a before/after comparison**. Main-thread leaf samples include Swift runtime, SwiftUICore and AttributeGraph work. Counts alone do not establish excessive view execution, hitches, or a rendering bottleneck. A UI automation interruption prevented the planned preview action in the second capture. No additional instrument was added to either successful capture.

Local evidence resides in `/tmp/rawbrowse-phase4/`: traces, exported sample XML, six timing logs, and `TimingBuild`/`TimingBuild.app.dSYM`. These are transient local files, not a durable trace archive. The copied matching symbols belong to the final timing build; earlier trace-build symbols were not separately preserved before rebuilding. Exported stacks remain available, but this limits future re-symbolication of those traces. The committed JSON contains timing-log hashes and all trial summaries. No raw environment export is committed.

## Decision and next experiment

Retain the diagnostics and cache baseline. The measured cache effect is not a gain from a new optimization. Empty-cache request latency is dominated by time awaiting `RawImageLoader.thumbnail`; that interval includes queueing, actor scheduling, file access and decoding, so it does not identify the root cause inside RawParserKit.

Next, create a minimal reproduction against the pinned RawParserKit revision, using the same first 56 files and pixel size. Record exact settings and window dimensions, then distinguish isolated parser calls from a viewport-sized concurrent batch. Use Time Profiler alone. Measure queueing versus decode/file-access work before trying a concurrency, priority or dependency change. Expand repetitions if the broad small-folder ranges persist.

Still pending: painted-frame/viewport readiness, rapid-scroll task counts, shared-task ownership under scrolling, detailed preview stages, separate sorting/publication timings, full memory attribution, JPEG workload coverage and matched phase 5 interaction/hitch checks. Phase 3 remains explicitly deferred because CLIP cadence was not measured.

## Validation and reproduction

Final diagnostic Release build and full macOS test suite passed with pinned packages, followed by `git diff --check`. The full suite was rerun after adding stderr capture. Logs: `/tmp/rawbrowse-phase4-instrumented-build.log`, `/tmp/rawbrowse-phase4-final-tests.log`.

Run the Release executable with `RAWBROWSE_PERFORMANCE_LOG=-` and a new sandbox-writable `RAWBROWSE_PERFORMANCE_CACHE_ROOT`; redirect stderr to a local file. Reuse that root in a fresh process for the paired warm trial. Follow the action sequence above, keeping the first 56 large-file requests complete before switching folders. Summarize with:

```sh
python3 Scripts/summarize-browsing-baseline.py LOGS... --output RESULTS.json
```

The summarizer checks unique interval identities, nonnegative intervals, fixed-cohort completeness and terminal results. Its output has per-stage counts/medians/ranges, cache outcomes, request windows and source hashes. The checked-in report JSON additionally records build/source identity, source-file verification and process-memory figures.
