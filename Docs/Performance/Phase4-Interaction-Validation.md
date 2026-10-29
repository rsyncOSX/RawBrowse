# Interaction validation and candidate recommendation

29 October 2026. Follow-up to the [rebuilt empty/warm comparison](Phase4-App-Warm-Comparison.md). One fixed interaction sequence per isolated sandboxed variant completed without an observed navigation or image-delivery failure. The temporary parser patch remains an upstream review candidate; production RawParserKit is unchanged.

## Procedure and observations

Both variants used the rebuilt Release binaries and matching configurations recorded in the warm-comparison JSON. Separate fresh disposable caches kept these instrumented runs out of the elapsed-time cohort. Launchers verified the executable and all initial 56 large-folder images. Baseline PID 4940; candidate PID 5039.

Sequence: scroll down three pages, up three pages, select the first grid image, press Right then Down, open JPG preview, press Right in preview, close preview, switch small then large. Preview filenames changed from `_DSC4603.ARW` to `_DSC4604.ARW` in both variants. Then scroll down six pages and immediately select the small folder without an intervening accessibility snapshot, return to large and scroll back up. Fresh accessibility state was used for each decision. Both settled grid screenshots showed populated, correctly oriented thumbnails, selection and the expected folder. Screenshots were inspected live; no screenshot artifact is retained.

Diagnostics verify that the second switch to small began while 152 large-folder thumbnail total intervals were active, in each variant. Both runs recorded 652 accepted thumbnail image assignments, 152 cancelled assignments and two accepted preview assignments. Peak registered thumbnail ownership was 152; all image tasks drained to zero before normal quit. Registered ownership is not simultaneous decode count. The same cancellation outcome counts support cleanup in this scenario, not an exhaustive cancellation or stale-state proof. No source files or sidecars were edited and post-run workload sizes/mtimes match.

## Time Profiler evidence

Used Blank plus Time Profiler only, attached to each verified PID for 45 seconds. Both accepted traces saved and exported nonempty `time-sample` data: baseline 11,656 rows / 9,020,054 bytes; candidate row/byte counts and all hashes are recorded in [the evidence summary](Phase4-Interaction-Results.json). Raw samples include stackshots and thread-state records, so row counts are not CPU time or SwiftUI executions.

The Mac locked before the first candidate sequence; that capture (`candidate.trace`) is excluded. After the user unlocked the Mac, `candidate-unlocked.trace` captured the candidate sequence. The baseline's later immediate-switch stress sequence occurred outside its capture; the candidate's was batched with its initial sequence. Tool pacing and covered windows therefore differ. These traces verify capture viability and preserve diagnostic stacks, but do not support a quantitative baseline/candidate CPU or responsiveness comparison. No hitch or first-painted-frame data was collected.

Large local evidence remains under `/tmp/rawbrowse-app-comparison/Interactions/`. The summary stores log/export hashes and trace metadata; the raw artifacts are transient and not committed. No user caches were cleared, indexing started or models downloaded. Both experiment apps quit normally.

## Decision

Retain the review patch and measured evidence; recommend upstream review of the explicit concurrent helper with the existing six-slot bound. The rebuilt app pairs reproduce 61%/72% lower empty-cache model-delivery windows for the large/small fixed cohorts. Warm disk bypasses the parser and shows no established benefit. Matching pixels in the earlier 82-file standalone comparison, 105 dependency tests, the post-fix full candidate app suite, two Release builds and these interaction checks support further integration review. They do not establish broader format coverage, exact CPU/memory tradeoffs in the app, or smoother frames.

Defer changing RawBrowse's published dependency pin until an upstream reviewed revision/release is available and validated. Do not publish or edit the sibling RawParserKit repository as part of this evaluation. The review patch is the concrete integration proposal. Additional work, if pursued, should target app memory/CPU cost under matched capture windows, mixed rendered/RAW inputs and painted-frame/hitch measurements. Phase 0/1 completeness and CLIP cadence remain unresolved; progress coalescing and phase 3 stay deferred without measured UI pressure. The current parser candidate evaluation is complete within this evidence scope; the full multi-phase program is not marked complete.
