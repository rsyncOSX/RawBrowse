# Temporary parser executor candidate

29 October 2026. Standalone candidate is promising; **not adopted in the app or dependency**. Next: matched sandboxed application trials. [Results and identity](Phase4-Executor-Candidate-Results.json); [reviewable uninstrumented dependency patch](Patches/RawParserKit-thumbnail-executor.patch).

## Change and initial failure

The pinned parser creates thumbnail worker tasks inside its actor and bounds decode admission with a six-slot `DecodeConcurrencyLimiter`. The candidate extracts the existing decode body into a private `@concurrent` async static helper. The same limiter awaits that helper. File selection, embedded-first/fallback logic, orientation handling, maximum pixel size, cancellation guards, task sharing and the six-slot count remain unchanged. This changes executor placement, not admission policy. Temporary metrics around work measure queueing and overlap; the review patch omits those metrics.

The first standalone candidate stalled in off-main first-use AppKit initialization during `NSImage(cgImage:size:)`, with one thread in display/TCC preflight initialization and others waiting on `dispatch_once`. The process was sampled read-only and terminated. This does not demonstrate a production app deadlock: the CLI harness had not initialized AppKit as a GUI application normally does. The harness now initializes NSApplication and a one-pixel NSImage on MainActor before measurement in **every variant**, and every configuration was rerun. No OS permission was granted or changed. Per-process timeouts now prevent an indefinite diagnostic stall.

This harness adjustment changes the baseline protocol. Compare variants in this update; do not combine their timings with the earlier uninitialized harness as if they were identical trials.

## Paired results

Three trials per input, caller concurrency 1/6/56, and variant (production Release object, instrumented unchanged copy, instrumented candidate): **54 processes, 2,214 returned images**. The same 82 unique ARW files at 200 pixels produced identical pixel dimensions and deterministic RGBA hashes in every run. No run failed. Data files retain individual values and source hashes. Trial order reverses on the middle trial; OS/storage caches are not flushed. Pixel hashing happens after the timed API and contributes to batch work.

| Workload, maximum callers | Production batch ms, trials 1/2/3 | Candidate batch ms, trials 1/2/3 |
| --- | --- | --- |
| Large, 56 | 398.96 / 397.76 / 400.65 | 110.48 / 112.78 / 110.02 |
| Small, 56 | 187.66 / 187.32 / 188.23 | 56.78 / 60.31 / 60.02 |

Large-batch median falls from 398.96 to 110.48 ms (about 72% lower); small-batch median from 187.66 to 60.02 ms (about 68% lower). These are standalone elapsed comparisons, not folder-opening or smoother-frame claims. Median production per-request times for the large 56-caller batch were 210.02–212.17 ms, versus 63.14–67.75 ms for the candidate.

Measured work overlap is exactly **one** in every instrumented unchanged 56-caller run and reaches **six** in every candidate run. This is direct evidence that executor placement exposes parallel decode work while respecting the existing six-slot bound for the tested input. Thread-at-end checks show no work ending on the main thread; those checks alone do not prove all execution remained off-main.

## Memory, CPU and profiling

Three additional paired fresh-process large/56-caller runs under `/usr/bin/time -l`:

- Production peak RSS: 48,463,872 / 48,660,480 / 48,480,256 bytes; candidate: 54,362,112 / 54,231,040 / 53,936,128 bytes.
- Production peak footprint: about 16.9–17.0 MB; candidate: about 22.7–22.8 MB (decimal units).
- Production user+system CPU: 0.47 / 0.49 / 0.47 seconds; candidate: 0.62 / 0.64 / 0.62 seconds.
- Whole-process real time including startup/output: production 0.63–0.65 seconds; candidate 0.24–0.25 seconds.

The candidate uses roughly 6 MB more peak memory and more CPU to complete sooner. These small CLI processes do not predict the app's multi-gigabyte runtime footprint. The candidate also carries the diagnostic metrics hook; the final review patch does not.

For Time Profiler, each already-running process initialized AppKit, wrote its PID, and waited for a local gate file. After attaching **Blank + Time Profiler only**, opening the gate ran 20 identical large batches. Both processes completed their output files; both recordings saved and exported nonempty CPU sample tables. Production: 8,090 CPU samples, 152 on the main thread; candidate: 11,466 samples, 201 on main. Leaf samples include CoreFoundation, AppleJPEG, allocator routines and ImageIO. The work is substantially off-main in these CLI captures. Sample totals are not an independent exact CPU measurement, and candidate interval-output overhead differs; use the uninstrumented application comparison before making UI claims.

Artifacts and matching symbols are retained under `/tmp/rawbrowse-parser-candidate-v2/`. The compiler now saves intermediate files in separate build directories so a subsequent `dsymutil` does not depend on deleted temporary objects. Both binary UUIDs and usable dSYM files are retained locally. Large traces and sample XML remain outside Git. The earlier stalled-process capture/sample are under `/tmp/rawbrowse-parser-candidate/` and are diagnostic failure evidence, not timing trials.

## Validation and next decision

The uninstrumented review patch was applied to a temporary copy of the pinned package, including its original tests. `swift test --configuration release` passed **105 tests in 16 suites**, including limiter-bound and cancellation tests. Neither the package checkout nor the sibling RawParserKit repository was edited. Application source and pinned versions remain unchanged by this update. Probe compilation, all 54 runs, pixel equivalence checks and `git diff --check` passed.

Next, build two temporary application copies from the same RawBrowse source: one with the pinned local package unchanged, one with this patch. Add the same opt-in configuration/task/presentation diagnostics to both. Capture actual window/settings identity and compare initial image delivery, cache behavior, scrolling and cancellation, then run the app's full tests for the candidate. Preserve the six-slot bound and assess CPU/memory tradeoffs. Keep the production dependency pinned until that evidence supports a retained change; otherwise finish with an explicit dependency recommendation or deferral.
