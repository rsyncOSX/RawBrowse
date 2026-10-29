# Sandboxed app comparison — rebuilt empty and warm trials

29 October 2026. Three new empty-cache/fresh-process warm-disk pairs per variant reproduce the temporary parser candidate's empty-cache model-delivery benefit. Warm-disk trials bypass the parser and establish no candidate benefit. Production RawParserKit is unchanged.

## Recovery and controls

The prior `/tmp` experiment directory, raw logs and disposable caches were absent on resumption. Rebuilt isolated Baseline/Candidate projects use app source hashes identical to the previous comparison and identical respective parser-loader hashes. All input-file sizes and nanosecond modification times match the workload manifest. Xcode 27.1 (27A9275). Source revision: `5aade3b`. Builds and full candidate tests finished before measurements.

New binary/dSYM UUIDs: Baseline `B3FEFB15-AA66-3495-A29A-E6C3FB375C6E`; Candidate `FE1CD43E-E92E-36E4-8EF2-8DB6D2F4989D`. New results are separate from the previous binary cohort; do not pool them. [Results JSON](Phase4-App-Warm-Comparison-Results.json) records source hashes, executable hashes, matching symbols, configurations and raw-log hashes.

Trial numbers 4–6 each use a fresh disposable cache for the empty process, then reuse that exact root in a fresh warm process. Order: B4 empty/warm, C4 empty/warm, C5 empty/warm, B5 empty/warm, B6 empty/warm, C6 empty/warm. Configuration matches all prior values, including the 1644×1272-point window at 2× and 200-pixel grid. OS/storage caches remain uncontrolled. Every launcher verified the executable and first 56 large-folder deliveries; both 56/26 fixed cohorts completed successfully in all 12 runs.

The normal sequence selects small, opens/closes its JPG preview, returns to large, opens/closes its preview, then revisits small/large in memory. Baseline empty 4 had two unusually slow automation calls (168 and 736 seconds), delaying small-folder selection; its previews were checked later, large first. These pauses are outside the per-cohort intervals but affect pacing/cache history. Later sequences took about 9–11 seconds. No interaction elapsed-time claim is made.

## Model-delivery results

Elapsed first request to final accepted image assignment in each fixed cohort, milliseconds. These are not painted frames.

| Condition/input | Baseline 4 / 5 / 6 | Candidate 4 / 5 / 6 | Baseline median | Candidate median |
| --- | --- | --- | ---: | ---: |
| Empty, large 56 | 991.56 / 978.46 / 904.87 | 381.83 / 362.14 / 382.75 | 978.46 | 381.83 |
| Empty, small 26 | 429.53 / 540.71 / 391.46 | 126.16 / 118.97 / 121.77 | 429.53 | 121.77 |
| Warm disk, large 56 | 59.79 / 69.35 / 58.41 | 72.55 / 58.60 / 73.89 | 59.79 | 72.55 |
| Warm disk, small 26 | 56.15 / 52.94 / 60.40 | 59.08 / 57.43 / 52.71 | 56.15 | 57.43 |

Empty-cache median windows decreased 61% and 72%. All warm-disk cohorts have zero parser intervals. Warm large candidate is 12.76 ms slower by median, with overlapping ranges; three runs do not resolve a regression or equivalence. Small warm ranges also overlap. The patch addresses parser work, not disk-cache lookup/decode.

Peak registered thumbnail ownership ranged 50–56. Baseline empty 5 and empty 6 recorded 25 and 14 cancelled presentation deliveries on later requests/revisits; their first fixed cohorts still completed. All other runs had no rejected delivery records. These records show rejection outcomes, not proof of cancellation responsiveness under a controlled rapid-switch load. All registered image tasks drained at log end. Previews and memory revisits completed. Raw logs and rebuilt products remain transient under `/tmp/rawbrowse-app-comparison`; committed summaries preserve hashes, not the raw evidence itself.

## Validation and decision

Both rebuilt Release apps passed. The full isolated candidate macOS suite passed after the JSON diagnostic correction (`candidate-tests.log`). Original photos and sidecars were not edited; user caches were not cleared. No new app production code or dependency pin is retained.

Retain the review patch and results as a supported upstream candidate. Production adoption remains deferred pending separate scrolling/folder-switch checks and Time Profiler evidence. First painted frame, hitch timing, full memory attribution, mixed formats, CLIP cadence and rapid non-cooperative cancellation are not established by these trials.
