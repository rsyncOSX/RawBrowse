# Parser round-trip isolation

29 October 2026. Retain the reproduction and measured queueing explanation. Application/dependency code is unchanged by this update. The next candidate is an executor-placement experiment in a temporary dependency copy, with the six-slot limit preserved.

## Reproduction and identity

`Scripts/measure-parser-roundtrip.py` links one optimized standalone probe against the exact existing Release `RawParserKit.o`. A second optimized probe compiles a temporary copy of the pinned package with one timing hook around its thumbnail limiter callback. The package checkout and application target remain unchanged. Both use Swift 6, MainActor default isolation, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, arm64/macOS 27 and optimization. The standalone caller submits requests at utility priority from a `@concurrent` function; it is not a SwiftUI workload or the sandboxed application.

[Full results](Phase4-Parser-Results.json) record the pinned package revision `07801a34a82d7720d301a80724c36a5b8c9f1d6c`, Release object hash, harness hash, instrumented source hashes, individual intervals and output checksums. Build/source artifacts and matching dSYMs are in `/tmp/rawbrowse-parser-probe-v2`. The first build attempt encountered read-only copied SwiftPM file modes; the script now makes only its temporary copied sources writable. Compiler macro-sandbox messages occurred during compilation, but both probes compiled and all trials completed successfully.

Inputs are the first 56 sorted ARW files in the authorized large catalog and all 26 in the small folder. Target size is explicitly **200 pixels** and `useRAW9` is false, matching the app's default grid request. The earlier application settings snapshot was not captured, so equivalence to its actual persisted target size is not established. There are no application disk or memory caches in this probe. OS/storage caches are not flushed. Each configuration runs in a fresh process; this does not mean cold filesystem caches.

Three trials for each workload, variant, and caller concurrency 1/6/56: 36 processes and 1,476 image results. Order alternates on the second trial to reduce one-way ordering bias. The first production sequential run is slower than later runs; all individual trials are retained. Per-image RGBA rendering and SHA-256 happen after the timed thumbnail API call; they add work to batch duration and can affect subsequent requests. All 82 unique source files produce identical pixel dimensions and pixel hashes across every variant/concurrency/trial. No image failed. This verifies output equivalence for this workload, not all image formats.

## Results

Milliseconds. Columns are medians of three per-trial values; request/wait/work columns are medians of the three per-trial medians, not pooled medians.

| Input | Caller concurrency | Production batch | Production request | Instrumented wait before work | Instrumented work |
| --- | ---: | ---: | ---: | ---: | ---: |
| Large, 56 files | 1 | 423.31 | 7.09 | <0.01 | 7.02 |
| Large, 56 files | 6 | 406.64 | 41.64 | 34.66 | 7.07 |
| Large, 56 files | 56 | 411.69 | 218.19 | 208.13 | 7.04 |
| Small, 26 files | 1 | 204.78 | 7.07 | <0.01 | 6.97 |
| Small, 26 files | 6 | 193.51 | 41.37 | 34.56 | 7.03 |
| Small, 26 files | 56 | 191.63 | 103.70 | 97.92 | 7.03 |

At 56 callers, production large-batch times are **403.68, 411.69, 428.10 ms**, with request medians **213.74, 218.19, 235.54 ms**. The corresponding instrumented batch times are **401.62, 404.75, 411.28 ms**. Instrumentation does not explain an order-of-magnitude slowdown in this comparison, although it remains a separately compiled diagnostic rather than an identical binary with tracing toggled.

The dependency configures six thumbnail limiter slots. Nevertheless, measured work intervals overlap at most **one at a time** in all six instrumented 56-caller trials. No interval ended on the main thread. These thread observations do not identify actor isolation. The wait interval starts before calling `limiter.run`, so it includes executor/mailbox waiting as well as any slot wait; it must not be presented as an exact measure of the limiter's continuation queue alone.

Increasing submitted requests raises per-request latency while batch throughput remains similar. This supports queueing before largely serialized work as a substantial component of round-trip time. It does **not** establish that the ImageIO decode itself takes hundreds of milliseconds per file, nor prove a specific executor is the serialization point. Application request times also include UI activity and different request order, so the standalone values are not a direct app speed comparison.

## Trace attempt and limits

A Blank + Time Profiler-only CLI launch created `/tmp/rawbrowse-parser-probe-v2/production.trace`, but the diagnostic did not write its completion file and the trace reports it was killed at the 10-second limit. The CLI recording command returned 54 even though its final message said recording completed. That capture is not used as evidence of completed parser work. Future standalone profiling should attach to an already-running gated process, as the successful application recordings did, and verify both completion output and nonempty CPU samples. No additional Instruments were enabled.

## Decision and next experiment

Keep the reproduction. Test moving only thumbnail decode work onto the concurrent executor in a **temporary** copy while retaining the six-slot limiter, API, cancellation checks and output orientation. Compare unchanged Release timings, instrumented unchanged timings and the candidate. Verify actual work overlap, output hashes, memory peaks and Time Profiler stacks. A faster diagnostic is insufficient for a production change: follow it with sandboxed application measurements and lifecycle validation, or record a dependency recommendation/deferral.

No app build/test rerun is necessary for this script/report-only update. Both probes compiled successfully, all 36 runs succeeded, interval counts matched file counts, all pixel hashes matched, and `git diff --check` passed.

Reproduce after a pinned Release build:

```sh
python3 Scripts/measure-parser-roundtrip.py \
  --products RELEASE_PRODUCTS_DIRECTORY --package RAWPARSERKIT_CHECKOUT \
  --output NEW_TEMP_DIRECTORY
```
