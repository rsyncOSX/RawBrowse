# Performance investigation continuation

Updated 29 October 2026 after completing rebuilt empty/warm comparisons and separate interaction checks. All experiment apps quit normally. Work is saved in reports linked from updates.md. No production dependency or sibling RawParserKit checkout was changed.

## Upstream review submitted

RawParserKit PR #8: https://github.com/rsyncOSX/RawParserKit/pull/8. Head `9b9f51280f9a55619dfcb4459b8f44d5493813ff`, branch `codex/bounded-thumbnail-executor`, base main `4b3bf40`. Prepared in `/tmp/rawparserkit-upstream-review`; sibling checkout unchanged. Current upstream loader/package settings match the evaluated baseline. Only implementation addition beyond the measured patch is an explanatory comment. The PR contains `Docs/ThumbnailExecutorEvaluation.md` with individual measurements and limitations. Both full Debug/Release package suites passed 105 tests with no warnings. No GitHub checks were reported at PR verification. No merge or release has been performed; production dependency pin remains unchanged. Next integration action depends on upstream review/release, not another executor experiment.

## Current decision

The temporary explicit concurrent-executor helper with the existing six-slot bound is supported for upstream review. Three rebuilt empty/warm pairs per variant show empty-cache model-delivery medians 978→382 ms (large) and 430→122 ms (small). Warm disk bypasses the parser and establishes no benefit. One matched interaction sequence per variant completed with equal accepted/cancelled assignment counts and task drain. Retain the review patch; defer production adoption until an upstream reviewed dependency revision/release is available and validated.

This candidate evaluation is complete within its stated scope. The overall phases are partial: first-painted-frame/hitches, matched app CPU/memory attribution, mixed formats, CLIP cadence and full phase 0/1 remain unresolved. Do not infer smoother frames from model assignment or CPU samples. Progress coalescing and phase 3 remain deferred.

## Reports and validation

- Phase4-App-Comparison.md / Results.json preserve the previous three empty-cache pairs and old binary identities.
- Phase4-App-Warm-Comparison.md / Results.json preserve the new twelve runs (trial numbers 4–6), source hashes, configurations, workload identity, executable/dSYM UUIDs and log hashes. Commit `4b19b9b`.
- Phase4-Interaction-Validation.md / Phase4-Interaction-Results.json preserve interaction outcomes, trace metadata and CPU-export hashes.
- Both rebuilt Release builds passed; full isolated candidate macOS tests passed after the diagnostic JSON correction. Earlier candidate package had 105 passing tests and matched output pixels across 82 files.

## Local state and evidence limitations

The previous temporary directory, raw logs and caches were absent at resumption. Rebuilt `/tmp/rawbrowse-app-comparison` has identical app and parser-source hashes but new binary UUIDs: baseline `B3FEFB15-AA66-3495-A29A-E6C3FB375C6E`; candidate `FE1CD43E-E92E-36E4-8EF2-8DB6D2F4989D`, both with matching dSYMs. Do not pool old/new binary cohorts. Trials 4–6 are under RunsFinal; do not overwrite them. Their caches are disposable roots in the sandbox container tmp. OS/storage caches were not controlled.

Interactions/ contains separate launches, traces and CPU exports. Baseline PID was 4940; candidate 5039. Accepted traces: baseline.trace and candidate-unlocked.trace. The earlier candidate.trace is excluded because the Mac locked before any UI actions. The user unlocked it, then the candidate sequence completed. Baseline later rapid-switch stress fell outside its capture; candidate stress was batched within its sequence. No quantitative CPU comparison is justified.

Baseline empty trial 4 had long automation pauses; subsequent trial sequences were compact. All fixed cohorts succeeded and tasks drained in all twelve runs. Workload sizes and nanosecond mtimes still match after interactions. Neither photos nor sidecars were edited. Original caches were not cleared. No models downloaded or indexing started.

## If further work is requested

Use an upstream reviewed revision/release for integration; do not invent/publish a dependency release. Additional measurements should address matched-window app CPU/memory, rendered/mixed inputs and actual painted-frame/hitch readiness. Keep optional CLIP experiments on disposable fixtures. Use Time Profiler alone if profiling; verify process executable, matching symbols, successful save and nonempty exports. CUA helpers must take explicit target objects; do not capture old app handles. Follow the existing Application-Experiment-Protocol.md and launch/delivery verification scripts. Save each completed update; never overwrite evidence or mix instrumented runs into latency trials.
