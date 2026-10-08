# RawBrowse review: concurrency, stale data and cancellation

The codebase is better than most for this. `LatestTaskRunner` plus token checks, the generation counters in `ModelDownloadsModel` and `CatalogStore`, and the lease-based security-scoped access are all deliberate and mostly correct. The problems are in the gaps between those pieces: places where cancellation is requested but not awaited, and places where state is published for the wrong context.

**What I read:** `Main/*`, `LatestTaskRunner`, `CatalogAccess`, `CatalogStore`, `BrowserContentsModel`, `SelectionModel`, `CLIPFeatureModel`, `DeepAIReviewFeature`/`Controller`, `DeepReviewModel`, `ModelDownloadsModel`, `ZoomModel`, `RAW9EditingSession`, `RAW9ExportQueue`, and some of the views.

**What I did not read:** `RAW9PreviewRenderer`, `RAW9SidecarStore`, `CLIPModelDownloadCoordinator`, `DeepAIReviewRuntime`, `BrowserImageLoader` and the disk caches, and most views. Findings that depend on those are marked "verify".

## High severity

### 1. Quitting the app silently kills exports and pending sidecar saves
`AppDelegate.swift` only implements `applicationShouldTerminateAfterLastWindowClosed → true`. It has no `applicationShouldTerminate`.

- The README says exports "continue after navigating to another photo or closing zoom". That holds only until the last window closes or the user presses ⌘Q.
- `RAW9ExportQueue` is an unstructured task, so the process just exits. Queued jobs are lost, and the active job can leave a truncated file at the destination.
- `RAW9EditingSession.scheduleRAW9SidecarSave` has a 300 ms debounce. An edit followed quickly by ⌘Q loses the edit. `finishSaving()` exists but nothing calls it at termination.
- Downloads and indexing are also abandoned mid-write. I couldn't verify whether `.clipindex` writes and download staging are atomic.

### 2. Cancelled indexing is not awaited, so a restart or validation can race the old writer
`cancelIndexing()` cancels the task and immediately sets `isIndexing = false`. It also calls `validateSelectedFolderCLIPIndex()` straight away.

- `canIndexSelectedFolder` becomes true while `engine.synchronize` is still unwinding. If it is non-cooperative inside a CoreAI call, that can be several seconds.
- The user can then press "Rebuild Index", or validation can read the `.clipindex` file while the old engine is still writing it. The same applies to `startIndexingSelectedFolder`, which cancels the previous task without awaiting it.
- The same pattern appears in `validateCLIPModel`, `deactivateCLIPModelRuntime` and `resetCLIPIndexSelection`.

### 3. Switching folders during indexing leaves stale index status for the indexed folder
`selectFolder` has no guard against `clip.isIndexing`. `isSidebarSelectionEnabled` only checks `isCreatingThumbnails`. `selectCatalog(newURL)` swaps `clipEngine` and `catalogURL` but does not cancel indexing.

- On completion, `validateSelectedFolderCLIPIndex()` validates the new selection, not the directory that was indexed.
- The indexed folder's entry in `catalogCLIPIndexes` stays at its pre-index status (for example `.notFound`). When the user navigates back, `useCatalogCLIPIndex` trusts the cache, so search is disabled until they click "Check Again".
- `isIndexing` is global, so the sidebar shows "Cancel Indexing" and progress for whichever folder is selected, not the one being indexed.
- `lastIndexSummary` is also attributed to the wrong folder.

### 4. Removing a model deletes the files before the runtime releases them
In `removeManagedCLIPModel`, `coordinator.remove(id)` runs first. The `locationsChanged` callback, which tears down `CLIPFeatureModel` and `DeepReviewModel`, fires only afterwards through `refreshCLIPModels()`.

- If indexing, search or Deep Review is running, or the provider just has the bundle mapped, the files vanish underneath it.
- Even after `activateModel(nil)`, teardown only cancels tasks and does not await them.

## Medium severity

### 5. Cancel does nothing during Deep Review preparation, and a cancelled run can overlap a new one
- `FileBrowserViewModel.startDeepReview` and `DeepReviewModel.startDeepReview` run CLIP classification and a per-file thumbnail and metadata loop. For `.full` scope on a large selection that can take a while.
- During that phase `DeepAIReviewFeature.state` is still `.idle`, so the `.preparing` state is only set later in `feature.start`. `isRunning` is false and `feature.cancel()` has no `task` to cancel. The Cancel button is a no-op, and "Run" stays enabled, so a second preparation can start. The second `feature.start` is then either dropped by `guard !isRunning` or runs a duplicate review.
- After `cancel()`, the state is `.cancelled` and `isRunning` is false immediately. The detached task may still be inside non-cooperative SAM 3 inference. Its results are correctly ignored through the generation check. But a new run starts a second SAM 3 inference concurrently, with memory pressure on the same model.
- `classifySubjects` runs on `clipEngine` with no check for `isIndexing`, so it competes with a running index.
- `selectFolder` and `removeRootCatalog` never cancel Deep Review.

### 6. The previous folder's files stay visible while a new folder scans
`BrowserContentsModel.scan` sets `selectedFolder` to the new folder but only assigns `files` when discovery finishes. On a slow or network volume the grid shows folder A's items under folder B's title.

- `selection.clear()` was already called, but `displayedFiles` is not cleared, so the user can click, zoom or ⌘C on a stale file.
- If discovery fails (unmounted drive, revoked permission), the result is an empty grid with no error. Nothing distinguishes "empty" from "inaccessible".
- `selectFolder` returns `false` silently when access can't be started.

### 7. A cancel that lands just after a successful download leaves the model "installed but inactive"
In `performCLIPModelDownload`, `try Task.checkCancellation()` can fire after the coordinator has already installed the model. The catch branch copies the state from a snapshot but does not update `managedCLIPModelLocations` or call `locationsChanged`. The UI says "Installed" while CLIP/SAM aren't activated until some later refresh.

Also verify that `refreshCLIPModels()` from `acceptModelLicence` for the *other* model doesn't overwrite an in-flight `.downloading(progress:)` state with a snapshot.

### 8. Export queue has no cancel, no removal, and keeps only the last error
- There is no way to cancel the active job or remove queued jobs, and no cleanup path for a partial destination file (verify in `RAW9PreviewRenderer.export`).
- `lastError` is overwritten, so several failures in a batch show only the last one.
- A sidecar save that fails *after* the user navigated away is dropped without a trace, because the error is only shown `if raw9AdjustmentURL == url`. There is no retry and no log, so adjustments are silently lost.

### 9. No refresh of on-disk changes
Folders are scanned once, with no rescan command and no file-system watcher. CLIP search results are never checked for existence.

- Files deleted, moved or added in Finder, or a drive unplugged, leave the grid, selection and search results pointing at missing files. They fail later as "Unable to load this image."
- A cheap mitigation is to filter results through an off-main existence check when publishing them. Another is to rescan on `NSApplication.didBecomeActiveNotification`.

## Lower severity and things to verify

- **`isCreatingThumbnails` is a plain public `var` that gates all sidebar navigation.** `scan()` resets it, but if the view that sets it is torn down or cancelled mid-batch, nothing guarantees it is cleared and sidebar selection stays disabled. I did not read the setter sites in the grid view. Prefer deriving it from an owned task with a `defer`.
- **Zoom navigation with held keys.** Each `N` or `P` repeat cancels the previous `zoomTask` and starts a new one. If `RAW9PreviewRenderer.zoom` is an actor with non-cooperative renders, cancelled renders still queue. The same applies to slider drags calling `refreshRAW9Preview`. Coalesce, or have the renderer check cancellation between stages.
- **`RAW9EditingSession.restore` awaits the pending save with no timeout.** A hung write (stalled network volume) blocks opening that image.
- **`DeepAIReviewFeature.results` grows without bound**, and `rebuildMaskCandidateIndex` is O(n) per result. It is also keyed by `BurstGroupSignature`. If that signature doesn't include modification dates, a file changed on disk yields a stale cached result.
- **`DeepReviewModel.validateSAM3Model`:** the guard that drops stale results comes after `deepAIReviewRuntime.activateSAM3(...)` has already called `controller.install(...)` (verify in `DeepAIReviewRuntime`). A cancelled, outdated validation could install a stale service.
- **Tests:** `ConcurrencyOwnershipTests` and `RAW9ExportQueueTests` exist. None of the scenarios above (cancel then immediately restart, folder switch mid-index, quit with queued exports, remove a model while in use) appear to be covered by name.

## Suggested fixes

All of these are sketches. Adapt names to your conventions.

### Fix 1: terminate gracefully (`AppDelegate.swift`, `RawBrowseApp.swift`)

```swift
// AppDelegate.swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App once the view model exists.
    var prepareForTermination: (@MainActor () async -> Bool)?

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        Task { @MainActor in
            app.reply(toApplicationShouldTerminate: await prepareForTermination())
        }
        return .terminateLater
    }
}
```

```swift
// FileBrowserViewModel+Termination.swift
extension FileBrowserViewModel {
    /// Returns true when it is safe to quit.
    func prepareForTermination() async -> Bool {
        await raw9.finishSaving()                       // flush debounced sidecar writes

        let queue = RAW9ExportQueue.shared
        if queue.outstandingCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Exports are still running"
            alert.informativeText = "\(queue.outstandingCount) export(s) will be lost if you quit now."
            alert.addButton(withTitle: "Wait and Quit")
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: await queue.waitUntilFinished()
            case .alertSecondButtonReturn: break          // ideally queue.cancelAll() + partial cleanup
            default: return false
            }
        }
        await clip.shutdown()                  // cancel + await indexing/search/validation
        deepReview.deepAIReviewController.cancel()
        downloads.cancelAll()                  // and clean staging dirs
        return true
    }
}
```

Wire it up in `RawBrowseApp` with `.task { appDelegate.prepareForTermination = { await viewModel.prepareForTermination() } }`. Also add `cancelAll()` and per-job cancel to `RAW9ExportQueue`, with partial-file removal on cancel or failure.

### Fix 2 and 3: await cancellation, and validate the folder that was indexed (`CLIPFeatureModel.swift`)

```diff
+    @ObservationIgnored private(set) var indexingDirectory: URL?
+    private(set) var isCancellingIndex = false

     var canIndexSelectedFolder: Bool {
         catalogURL != nil && clipProvider != nil
-            && !isIndexing && !isSearching
+            && !isIndexing && !isSearching && !isCancellingIndex
     }

     func cancelIndexing() {
-        indexingID = UUID()
-        indexingTask?.cancel()
-        indexingTask = nil
-        isIndexing = false
-        indexingProgress = nil
-        validateSelectedFolderCLIPIndex()
+        guard let task = indexingTask else { return }
+        let directory = indexingDirectory
+        indexingID = UUID()
+        indexingTask = nil
+        isCancellingIndex = true
+        task.cancel()
+        Task { [self] in
+            await task.value                 // old writer has really stopped
+            isCancellingIndex = false
+            isIndexing = false
+            indexingProgress = nil
+            indexingDirectory = nil
+            if let directory { validateCatalogCLIPIndex(at: directory) }
+        }
     }
```

In `startIndexingSelectedFolder`, set `indexingDirectory = directory`, and `await` any previous task before creating the new engine. On completion, replace `validateSelectedFolderCLIPIndex()` with `validateCatalogCLIPIndex(at: directory)` and clear `indexingDirectory`. Make the sidebar's "Cancel Indexing" and progress UI show only when `clip.indexingDirectory == clip.catalogURL`. Alternatively, make `isSidebarSelectionEnabled` false while `clip.isIndexing`, the simplest option.

### Fix 4: release the runtime before deleting a model

```diff
 // ModelDownloadsModel
+@ObservationIgnored var willRemoveModel: (@MainActor (CLIPModelDownloadID) async -> Void)?

 func removeManagedCLIPModel(_ id: CLIPModelDownloadID) async {
     guard clipModelDownloadTasks[id] == nil else { return }
     clipModelDownloadStates[id] = .removing
+    await willRemoveModel?(id)      // runtimes cancel, await, and drop provider/service
     do { try await clipModelDownloadCoordinator.remove(id) ...
```

In `FileBrowserViewModel.init`, set `downloads.willRemoveModel` to call `await clip.shutdown()` for the selected CLIP model, or `await deepReview.shutdown()` for `.sam3`. Each `shutdown()` cancels and awaits its tasks, then nils the provider and engine.

### Fix 5: Deep Review preparation as a cancellable, single-flight phase

```swift
// FileBrowserViewModel.swift
private(set) var isPreparingDeepReview = false
@ObservationIgnored private var deepReviewTask: Task<Void, Never>?

var canDeepReviewSelection: Bool {
    shouldPresentDeepReviewAction && !isPreparingDeepReview
        && !deepReview.deepAIReviewController.isActionUnavailable
}

func startDeepReview(groupID: Int, groupSignature: BurstGroupSignature, files: [BrowserFileItem]) async {
    guard !isPreparingDeepReview else { return }
    isPreparingDeepReview = true
    defer { isPreparingDeepReview = false; deepReviewTask = nil }
    let task = Task { /* existing body */ }
    deepReviewTask = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

func cancelDeepReview() {
    deepReviewTask?.cancel()
    deepReview.deepAIReviewController.cancel()
}
```

Point the sheet's Cancel button at `cancelDeepReview()`, and call it from `selectFolder`, `removeRootCatalog` and `clearRememberedCatalogs`. In `DeepAIReviewFeature.start`, keep the previous detached task and `await previous?.value` before launching a new one, so two SAM 3 inferences never overlap.

### Fix 6: no stale grid during a scan (`BrowserContentsModel.scan`)

```diff
 func scan(_ folder: BrowserFolderItem, access: CatalogAccessLease?) -> Task<Void, Never> {
+    if selectedFolder?.id != folder.id { files = [] }
     selectedFolder = folder
```

Also surface an `accessError` when `selectFolder` returns false or discovery fails on a non-existent or unreadable path.

### Fix 7: refresh after a late cancel (`ModelDownloadsModel`)

```diff
 } catch is CancellationError {
-    let snapshot = await clipModelDownloadCoordinator.snapshot()
-    clipModelDownloadStates[id] = snapshot.states[id] ?? .ready
+    await refreshCLIPModels(allowCancelled: true)   // updates states AND locations, fires locationsChanged
 }
```

## Suggested next steps

1. Hand fixes 1–7 to the coding agent to open a pull request, with tests for cancel-then-restart, folder switch mid-index, and quit with queued exports.
2. Review the files not yet read (`RAW9PreviewRenderer`, `RAW9SidecarStore`, `CLIPModelDownloadCoordinator`, `DeepAIReviewRuntime`, `BrowserImageLoader`, grid and zoom views) to confirm the "verify" items.
3. Draft a focused PR for just the four high-severity items (termination, awaited indexing cancel, folder switch during indexing, model removal ordering).
