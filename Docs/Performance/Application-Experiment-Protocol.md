# Matched application experiment protocol

29 October 2026. Extends the opt-in baseline diagnostics without changing loading policy or dependency pins. Diagnostic Release build and full macOS suite passed (`/tmp/rawbrowse-app-diagnostics-build.log`, `/tmp/rawbrowse-app-diagnostics-tests.log`).

New evidence points:

- Workspace configuration event: executable path, visible window/content dimensions and display scale, actual grid/preview/full-size pixel settings, cache limits and selected CLIP model ID. No credentials or bookmarks are logged.
- File enumeration, metadata/filtering, sorting and synchronous list publication are separate intervals.
- Thumbnail parser/total intervals carry target pixel size. Registration/completion events identify shared workers and active thumbnail/preview task counts; shared waits are separate events.
- Thumbnail model delivery measures accepted image assignment, including memory-cache paths. Superseded/cancelled deliveries are labelled. It does not measure a painted frame.
- Preview disk lookup, extraction, source-JPEG retrieval/save, resize and model image delivery are separated. Delivery excludes the later metadata wait; it does not measure a painted frame.

`Scripts/prepare-parser-app-experiment.py` copies the same app sources into separate temporary Baseline/Candidate projects and copies the pinned RawParserKit package twice. Only the candidate package receives the review patch. Each temporary project changes its package reference to its own local copy. It verifies identical app-source hashes across variants. The real project, Package.resolved, installed application and package checkout are not changed. Xcode products and matching symbols stay separate.

Paired procedure:

1. Finish builds/tests before measurements. Record executable and dSYM UUIDs and verify the running PID's executable path. Use the same restored window and reject mismatched configuration snapshots.
2. For each empty-cache trial, choose a new sandbox-writable diagnostic cache root for both image cache types; capture stderr outside the sandbox via an inherited descriptor. Do not clear user caches or source catalogs. OS/storage caches remain uncontrolled.
3. Restore the large catalog, wait for the fixed first-56-file model-delivery cohort, select the small folder, wait for its 26-file cohort, open/close its first JPG preview, return to the large folder, and open/close its first JPG preview. Revisit both in memory. Record delivery outcomes rather than treating any interval termination as success.
4. Repeat three times per variant, alternating variant order. Run paired fresh processes against the populated roots to test warm disk separately. Keep whole-process memory distinct from cache-specific memory.
5. In separate interaction runs, exercise a fixed down/up scroll sequence, keyboard selection, preview open/close and folder switching during loading. Inspect task buildup/drain and stale model-delivery rejection. Capture screenshots at settled checkpoints for visual correctness; screenshots and accessibility calls are not frame-time measurements.
6. Use Blank + Time Profiler only for short captures, attached to the verified process. Verify successful save, nonempty exported CPU samples and operation completion. Keep those instrumented runs separate from elapsed comparisons. Do not infer hitches or SwiftUI view execution counts from CPU samples.

The baseline and candidate copies were prepared under `/tmp/rawbrowse-app-comparison/`; their source identity manifest is `identity.json`. All traces and large local build products stay outside Git. No speed claim or production dependency adoption is made by this protocol update.
