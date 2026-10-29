# Sandboxed app comparison — empty-cache results

29 October 2026. The temporary parser executor patch improves **model image delivery** in repeated sandboxed app trials. It is applied only to the isolated Candidate app, **not** the real RawBrowse dependency pin or sibling RawParserKit repository. Warm-cache comparison, interaction captures and final acceptance remain pending due to the user-requested usage reserve.

## Identity and controls

[Results](Phase4-App-Comparison-Results.json) include raw-log hashes, source hashes, matched settings/window identity and executable/dSYM identities. Current matching UUIDs:

- Baseline: `3407340B-8D34-3294-8A6C-6C3BB744D0F8`.
- Candidate: `3195912B-7FC4-3ADF-BC66-C35E165C0F0C`.

Both Release apps use identical RawBrowse sources and normal sandbox entitlements. Temporary local parser copies differ only by the uninstrumented [review patch](Patches/RawParserKit-thumbnail-executor.patch), retaining the existing six-slot limit. Real project pins and checkouts are unchanged. Actual settings match: 200-pixel grid, 1616-pixel preview, 8700-pixel full-size, 768 MB cache settings, four cached previews, `clip-datacomp`; window 1644×1272 points, content 1644×1220, scale 2×.

Each trial starts with a unique disposable thumbnail/full-size cache root in the app's container tmp. OS/storage caches remain uncontrolled and likely warm from prior work. Builds, tests and profiler recordings did not overlap accepted timing sequences. Launch Services supplies diagnostic environment and stderr capture. The launcher verifies executable identity and the initial 56 successful model deliveries before interaction begins.

Order: baseline-1, candidate-1, candidate-2, baseline-2, baseline-3, candidate-3. After large-folder startup, each correct-target UI sequence selected the small folder, opened/closed its first JPG preview, returned to the large folder and opened/closed its first preview, then revisited both folders in memory. The fixed initial cohorts are first 56 filenames in the large catalog and all 26 small-folder ARWs. First model-delivery intervals for those paths must all terminate with `image`; otherwise the summarizer rejects the run. Every trial passed cohort checks and owned-task drain before normal quit.

## Results

Elapsed window from the earliest initial model request to the last accepted model image in its fixed cohort, milliseconds:

| Input | Baseline trials 1 / 2 / 3 | Candidate trials 1 / 2 / 3 | Baseline median | Candidate median |
| --- | --- | --- | ---: | ---: |
| Large, 56 images | 927.33 / 806.62 / 864.48 | 384.50 / 394.08 / 317.26 | 864.48 | 384.50 |
| Small, 26 images | 378.19 / 422.70 / 496.19 | 142.38 / 140.03 / 125.52 | 422.70 | 140.03 |

The median cohort window is about **56% lower** for the large catalog and **67% lower** for the small folder. Per-request model-delivery medians also fell: large baseline 513.48–578.12 ms versus candidate 224.93–322.07 ms; small baseline 219.84–349.47 ms versus candidate 97.56–108.45 ms. Individual values and stage timings are retained in the JSON rather than inferred from screenshots.

Peak registered owned thumbnail tasks was 56 in each of the six sequences, and all registered image tasks drained to zero. That measures app worker ownership, not the number of simultaneously executing parser decodes. The standalone experiment separately verified six-way work overlap for the candidate.

These are model assignments, **not painted-frame times, complete catalog latency or hitch measurements**. No claim of smoother frames follows. Preview open/close and in-memory revisits worked in the fixed sequence, but this does not replace the remaining warm-disk and rapid-interaction experiments. The standalone candidate's higher CPU/memory cost remains a tradeoff to assess in the app.

## Exclusions and limitations

Pre-fix setup launches are excluded. The configuration logger originally passed a Swift enum into Foundation JSON encoding; `dc2b6e2` fixes raw-string serialization and guards unsupported values, with two regression tests. Earlier UI helpers also captured the root-project app rather than the explicit temporary target. Those wrong-target actions are excluded; the six accepted logs contain the verified executable/configuration, both image cohorts and task drain. Subsequent helpers take the app target explicitly.

Baseline trial 1's initial large cohort completed before a long setup pause; its small-folder sequence occurred later. Other trials followed the compact fixed sequence. No wall-clock time across that pause enters the reported request windows, but run pacing and background cache history are limitations. No OS cache flush or physical-storage claim is made.

Source-file sizes and nanosecond modification times still match both workload manifests after the trials. Neither original photos nor sidecars were edited. No user cache was cleared and no indexing was started. Traces and raw logs stay outside Git under `/tmp/rawbrowse-app-comparison/`; their summaries and hashes are committed. Local artifacts are transient.

## Validation and decision

The uninstrumented candidate package passed 105 tests. The isolated candidate app's full macOS suite passed before the diagnostic JSON correction; after that correction the root app's full suite, root Release build and both temporary Release builds passed. Candidate full-suite revalidation after the correction is still pending and must not be represented as completed. Both current app binaries have matching dSYMs.

Retain the measured candidate and review patch as evidence; defer production adoption until warm-disk comparison, interaction/cancellation checks, separate Time Profiler captures and final candidate tests are complete. The production project still uses RawParserKit 1.3.2 at its original revision. Do not publish or invent an upstream release to change the pin. Resume from [CONTINUATION.md](CONTINUATION.md).
