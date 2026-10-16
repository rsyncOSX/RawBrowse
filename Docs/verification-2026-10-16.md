# Document-to-code verification

Verified on 2026-10-16 against the current working tree. This is a source and existing-test audit; no application code was changed.

## Docs/RawCullFixPort.md

All six described implementation changes are present. The historical claims about successful Xcode runs were not independently reproduced.

| Item | Status | Evidence |
| --- | --- | --- |
| Keyboard scope | Applied | `ReviewKeyboardScope.accepts` requires the anchored key window and rejects attached sheets, modal windows, and native input controls. `BrowserZoomOverlayView.installKeyMonitor` uses the scope and retains RAW adjustment Command-C/V handling. No accessibility focus query is used. `ReviewKeyboardScopeTests` covers the scope. |
| Thumbnail identity/publication | Applied | `ThumbnailRequest` includes URL, size and source fingerprint. `ThumbnailPresentationModel.load` checks cancellation, generation and the current source fingerprint before publication. `BrowserThumbnailCell` invalidates on disappearance. `ThumbnailPresentationTests` and `FullSizeJPGDiskCacheTests` contain regression coverage. |
| Settings initialization | Applied | `SettingsModel` starts live stores unread, rejects premature mutation/persistence, coalesces reads through `loadTask`, supports retry, and awaits loading/saving at shutdown. Explicit initial values start ready. `SettingsInitializationTests` covers admission and failures. |
| Reduce Motion | Applied | `FileBrowserView` reads `accessibilityReduceMotion` and clears/disables animations for the browser and zoom subtree. `BrowserTransitionTests` exists. Preference-toggle behavior still needs manual verification. |
| Test cache isolation | Applied | `BrowserFileDiscoveryTests` injects a temporary full-size cache; `FullSizeJPGDiskCacheTests` verifies independent injected caches and reopening a cache. |
| J/R source shortcuts | Applied | `ZoomOverlayKeyAction` resolves J/R; the overlay handles them through both its monitor and SwiftUI key handling. RAW rejects rendered-image inputs, and changing `useDevelopedRAW` follows the existing reload path. Actual RAW switching still needs manual verification. |

## Docs/review.md: numbered findings

| Finding | Status | Evidence / remaining work |
| --- | --- | --- |
| 1. Termination | Partly applied | `AppDelegate.applicationShouldTerminate` defers termination; `RawBrowseApp` wires it to `FileBrowserViewModel.prepareForTermination`. That method drains sidecar saves, exports and settings, and prevents quitting on unsaved changes. It does **not** stop/drain indexing, search, Deep Review or downloads. It always waits for exports, with no quit/cancel choice. `FeatureOwnershipTests` covers export/save waiting and failed saves. |
| 2. Index cancellation/restart | Partly applied | `cancelIndexing` now retains task ownership and leaves `isIndexing` true until the worker exits, preventing immediate restart through that path. However, `validateCLIPModel`, `deactivateCLIPModelRuntime` and `resetCLIPIndexSelection` still cancel/drop indexing and clear `isIndexing` without awaiting it. `validateCatalogCLIPIndex` also has no guard against validation during an active writer. The stronger drain is used by `deactivateAndWait`, particularly during removal, but not every runtime transition. |
| 3. Folder switch while indexing | Partly applied | The worker validates its captured `directory`, and summaries are stored per URL. `CLIPFeatureTests` verifies summary attribution. But folder navigation remains enabled during indexing, and `SidebarIndexPanel` shows global progress/cancel controls without comparing `indexingDirectoryURL` to the selected catalog. |
| 4. Model removal order | Applied in the normal removal path | `ModelDownloadsModel.removeManagedCLIPModel` awaits `prepareForRemoval` before deleting files. Composition drains Deep Review and CLIP for CLIP removal, and deactivates/drains SAM for SAM removal. CLIP tracks replaced tasks and drains the search runner. `FeatureOwnershipTests` covers draining a replaced search; a full model-removal-during-inference regression is still absent. |
| 5. Deep Review preparation/cancellation | Partly applied | `startPreparing` owns preparation in the same task, publishes `.preparing` immediately, propagates cancellation, and rejects replacement while the old task drains. The preparation loop checks cancellation. `FeatureOwnershipTests` covers non-cooperative preparation and restart admission. However, classification has no `isIndexing` guard, and `selectFolder`, `removeRootCatalog` and `clearRememberedCatalogs` do not cancel Deep Review. |
| 6. Stale grid and scan errors | Partly applied | `BrowserContentsModel.scan` clears files immediately and records `scanError`; stale scan publication is guarded. Existing ownership tests cover clearing and replacement. But no browser view reads `scanError`, and `selectFolder` still returns false silently when access cannot start. |
| 7. Late download cancellation | Not applied | The cancellation catch in `performCLIPModelDownload` still copies only `snapshot.states[id]`. It does not update installed locations or call `locationsChanged`, so installed-but-inactive remains possible. `refreshCLIPModels` still replaces the whole states dictionary without preserving locally active downloads; whether the coordinator snapshot itself preserves progress requires inspection of the dependency. |
| 8. Export cancellation/errors and sidecar failures | Partly applied | Export waiting at termination is present, but the queue has no cancellation/removal API and still exposes only `lastError`. Failed sidecar revisions remain tracked, preventing silent successful termination, but errors after navigation are still suppressed by the current-URL check. No per-file retry or retained adjustment snapshot for retry was found. Partial-file behavior depends on the renderer dependency. |
| 9. Disk changes | Not applied | No refresh command, activation rescan, or filesystem watcher was found. `startSearch` publishes all returned URLs without an existence check. |

## Lower-severity and verification items

| Item | Status |
| --- | --- |
| Thumbnail navigation gate | `isCreatingThumbnails` remains publicly mutable. Current source only initializes/resets it to false; no code sets it true, so the documented stuck-true path is currently dormant. |
| Zoom render backlog | `ZoomModel` still cancels/replaces tasks without coalescing or awaiting renders. Publication checks exist. Whether cancelled renders consume expensive work requires the renderer dependency. |
| Hung sidecar restore | Still awaits the previous save without a timeout. |
| Deep Review result retention/index cost | Still stores results without an explicit bound and rebuilds the candidate index from all results on completion. |
| Deep Review signature freshness | Applied: `BurstGroupSignature` uses file UUID plus `ImageSourceFingerprint`; tests cover catalog/revision/rescan identity. |
| Stale SAM installation | The outer guard remains after activation, but the current `DeepAIReviewRuntime.activateSAM3` performs no suspension inside its main-actor implementation. A newer main-actor validation cannot interleave with its synchronous installation, so the alleged stale-install race was not confirmed in this implementation. |
| Atomic index/download/export writes | These implementations are in package dependencies, absent from this checkout. `CLIPFeatureTests` includes a cancelled-index-save preservation test and `RAW9ExportQueueTests` includes encoded export create/replace coverage, but these were not run in this audit. |
| Regression coverage | More coverage exists than the original review describes: termination, stale scans, preparation cancellation, summary attribution, replaced-search shutdown, and source fingerprints. Direct indexing cancel/restart, full folder-switch-mid-index, late-install cancellation, and model deletion during inference coverage remains incomplete. |

## Validation limitation

Attempted:

```sh
xcodebuild -project RawBrowse.xcodeproj -scheme RawBrowse -destination 'platform=macOS' -derivedDataPath /tmp/RawBrowse-doc-audit test
```

Package resolution failed before compilation because `github.com` could not be resolved. No tests were executed. Log: `/tmp/RawBrowse-doc-audit.log`.

The pre-existing deletion of `Docs/aimodelsdownload.md` was left untouched.
