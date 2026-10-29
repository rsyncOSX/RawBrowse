# Performance investigation continuation

Updated 29 October 2026. User authorized autonomous continuation within available usage, Time Profiler alone for Instruments, and a commit after each completed update. Save/commit and update this handoff before usage is exhausted. Do not ask routine permission questions. No subagents were requested or used.

## Committed work

- `c94b8b8`: first browsing baseline and opt-in diagnostics (user committed).
- `e62938f`: parser queueing reproduction and 36 trials against the pinned Release object/instrumented copy.
- `49b723d`: bounded concurrent-executor candidate, 54 successful runs with matching pixels, reviewable dependency patch and 105 passing dependency tests.
- `168a6f3`: settings/window, discovery, task-count and model-delivery diagnostics; isolated app preparation script.
- `dc2b6e2`: configuration JSON crash fix, regression tests, verified launch/delivery helpers. Full root app tests and Release build passed afterward. Both temporary Release apps were rebuilt with the same fix.

## Findings and scope

The parser's existing six-slot limit does not itself ensure parallel execution: unchanged probe work overlapped at most once, versus six times with the temporary `@concurrent` helper. At 56 callers, large standalone batches fell from about 399–401 ms to 110–113 ms; small batches from 187–188 ms to 57–60 ms. Output pixels matched for all 82 files. Candidate used about 6 MB more peak memory and more CPU. It is **not adopted in the production dependency**. See the linked reports in updates.md and the patch under `Docs/Performance/Patches/`.

The actual app comparison is in progress. No loading-speed or smoother-frame claim is established yet. Model delivery is not a painted frame. Phase 3 CLIP coalescing remains explicitly deferred; progress optimization has no measured app/UI-cost justification. Existing download correctness fixes predate this work.

## Local experiment state

- Root: `/tmp/rawbrowse-app-comparison` (canonical `/private/tmp/...`).
- Apps: `{Baseline,Candidate}Build/Build/Products/Release/RawBrowse.app` under that root. Sources: `{Baseline,Candidate}/App`; local parser copies beside them. Only candidate parser has the uninstrumented review patch. Real project and dependency pins are unchanged.
- Source identity manifest: `identity.json` (updated after the JSON fix). App sources must match across variants.
- Initial pre-fix binary UUIDs were Baseline `C6A32C97-5163-365D-A1FC-B14543E6AABC`, Candidate `0E072F9C-91B1-309C-9D17-A5C689B9B93F`. **Re-read current UUIDs after the fix; do not reuse these for final evidence.** Separate dSYMs are next to both apps.
- Full candidate app suite passed before JSON fix (`candidate-tests.log`); after the fix the root full suite passed (`/tmp/rawbrowse-diagnostics-json-tests.log`), and root Release plus both temporary Release builds passed. Candidate full suite should be rerun after the fix for final acceptance.
- Accepted logs go in `RunsFinal/`; other `Runs/` files and failed launches are setup-only evidence and must not be pooled into trials.
- First accepted run: `RunsFinal/baseline-empty-1.jsonl` and its `.launch.json`. Big 56 and small 26 image cohorts delivered; owned image tasks drained to zero. Both first-image previews and memory revisits were exercised. The run was closed normally. Its large-startup cohort was separated by a long setup pause before small-folder actions; disclose that or replace with a cleaner trial if necessary.
- First accepted configuration: grid 200 px, preview 1616 px, full-size 8700 px, cache settings 768 MB, four cached previews, `clip-datacomp`, window 1644×1272 pt, content 1644×1220 pt, 2× scale.

## Pitfalls already resolved

1. Standard Time Profiler template enabled extra logging/Hangs and could fail exports. Use `xcrun xctrace record --instrument 'Time Profiler' --attach PID ...` (Blank + Time Profiler only), verify saved trace and nonempty CPU export. Standalone gated profiling worked. No extra Instruments.
2. CLI parser harness needed main-thread AppKit initialization; all 54 final trials were rerun after that change. First stalled run is excluded.
3. Configuration event initially contained a Swift enum, causing configured launches to exit. Fixed by raw string IDs and `isValidJSONObject` guard, with tests. Exclude pre-fix app launches.
4. A reused CUA helper captured the **earlier root-project app**, so some UI actions reopened it without diagnostics. This is a helper-target error, not evidence the experiment app changed. Use explicit target parameters for every action. No CUA interaction data from those wrong-target sequences is accepted. Corrected baseline run has verified small-folder deliveries and task drain.
5. MacOS protects container files from terminal reads. Log through inherited stderr with Launch Services `open --env ... --stderr ...`; place disposable image caches in the app's container tmp. Never clear user caches.

## Reproducible launch and UI sequence

First close the previous experiment normally. The launcher refuses existing RawBrowse processes and evidence overwrites:

```sh
python3 Scripts/launch-performance-app.py --root /tmp/rawbrowse-app-comparison \
  --variant baseline --state empty --trial 1
```

That exact trial already exists. Continue with candidate empty 1, then paired warm processes, then trials 2/3 (reverse variant order in the middle trial). `--state warm` reuses its variant/trial cache identity. It verifies all 56 initial large-cohort model deliveries and recorded executable before returning. Use sandbox escalation for the launch/process inspection tools as needed; prior authorization covers these actions.

CUA bindings exist in the current session, but context compaction requires `cua.rewriteDocumentation()` before continuing computer use. Do not rely on old global helper closures. A safe helper takes `target` explicitly, obtains fresh full AX state, finds the current line by label, clicks its current numeric index, then gets fresh state. Sequence after startup:

1. Select sidebar `row (selectable) 06_mai_2026`.
2. Open toolbar `button Description: Preview,`, close `button Description: Close, ID: xmark.circle`.
3. Select `row (selectable) 100MSDCF`, open/close first preview.
4. Revisit small, then large in memory.
5. `python3 Scripts/wait-for-image-delivery.py LOG --folder 06_mai_2026 --drained` must pass, then quit normally using the **same explicit app target**.

No builds/tests/profiling should overlap elapsed trials. Both app copies are sandboxed. Use normal GUI Launch Services startup rather than guessing a direct-executable launch worked. Never count a run lacking configuration and successful cohort records.

## Next work, in priority order

1. Complete three empty-cache/warm-disk pairs per variant; record current binary/dSYM UUIDs and verify matched configurations. Summarize initial per-path accepted presentation deliveries, parser/lookup/save stages, separate discovery/sorting/publication, previews, task peaks/drain, stale/cancelled deliveries. Keep full logs/traces outside Git; commit compact summaries with evidence hashes.
2. Run matched short interaction sequences (scroll down/up, keyboard selection, preview open/close, switch folders while loading) with explicit CUA targets. Verify visible results and task drain. Attach Time Profiler alone to the verified PID for separate captures. Do not infer hitches or painted-frame timing from samples/accessibility.
3. Rerun candidate full macOS tests after JSON fix. Existing root and package suites already cover cancellation/ownership; add a test only for a demonstrated missing contract. Preserve originals and sidecars; verify input manifests afterward.
4. Optional if usage permits: CLIP cadence on a disposable symlink/copy fixture rather than creating indexes in the user's original catalogs; no model download needed. Otherwise retain explicit CLIP deferral. Mixed JPEG behavior, full memory attribution and first-painted-frame metrics remain limitations unless independently measured.
5. Decide retain/defer/reject. A promising standalone patch is insufficient to change the published dependency pin. Avoid editing/publishing the sibling RawParserKit repository without a concrete supported integration/release plan. A validated review patch plus explicit upstream dependency recommendation is an acceptable investigation outcome.
6. Update updates.md and final report; commit each completed update. Check usage and leave time to update this continuation and commit all reviewable work before the remaining allowance is exhausted. Do not claim all phases passed if required evidence remains missing.

## Other evidence

`/tmp/rawbrowse-parser-probe-v2`: initial 36-trial reproduction. `/tmp/rawbrowse-parser-candidate-v2`: final 54-trial results, metrics, matching symbols, successful gated profiler traces/exports, paired memory measurements and the uninstrumented candidate package with 105 passing tests. `/tmp/rawbrowse-phase4`: earlier baseline logs/traces. These are transient local artifacts; important summaries are committed in Docs/Performance.
