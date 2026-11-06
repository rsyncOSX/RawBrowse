# Close-ups integration

Reusable contracts, crop engine, models and UI now live in the sibling local
Swift package `../PhotoEvidenceKit`. RawBrowse links PhotoEvidenceContracts,
PhotoEvidenceEngine and PhotoEvidenceUI; it contains no second implementation.

This folder owns only the host adapters:

- BrowserCloseUpFrameAdapter reads source fingerprints off the UI actor under
  catalog access leases. Session UUIDs are not used as durable source revisions.
- BrowserCloseUpRenderer bounds in-flight work, obtains oriented previews through
  the existing loader and delegates geometry/rasterization to PhotoEvidenceEngine.
- BrowserCloseUpRegionStore stores versioned manual regions in UserDefaults,
  validating source identity/revision when the package restores them.
- BrowserCloseUpsView supplies selected frames and current-image identity, and
  handles explicit Show image actions without changing multi-selection.

The right-hand panel supports Pin/Replace/Unpin reference, independent regions,
relative linked pan/zoom, unlink/reset and saved regions across navigation and
relaunch. Pinning is temporary and never changes ratings or winners. Reset region
is saved; Reset view changes only temporary inspection. JPG mode uses embedded previews. The main preview's RAW selection applies to
all selected cards and a retained reference: RAW9 when supported, otherwise the
existing RAW development path. Source-pixel crops use native decoded dimensions,
not the fit-sized main preview. A pinned reference survives selection changes but Show image is offered
only for selected images the host can activate.

Run package tests from PhotoEvidenceKit, and RawBrowseTests/CloseUpTests for source
revision and preference-store integration. No RAW files or XMP sidecars are written.

## Render-source contract

BrowserCloseUpSourcePlanner captures backend, bit depth and per-file settings into
immutable BrowserCloseUpRenderPlan values. Package CloseUpRenderSource revisions
change on live RAW9 edits, sidecar/settings versions and bit depth; file fingerprints
remain separate so a source switch preserves manual regions. Current/unsaved settings
are read through RAW9EditingSession.adjustmentsSnapshot without changing the active
editing file. Other candidates load their own sidecars; current settings are never
copied onto another photograph.

BrowserCloseUpDecodedSource obtains native oriented images and maps canonical
regions through RAW9 straighten-then-crop geometry. Output labels show the actual
backend/depth and developed dimensions. The renderer captures the exact plan before
queuing work, validates file identity, and returns the matching package descriptor.
No decoded request falls back silently to the embedded JPG. Decode/probe failures
remain visible; refresh the selection after an external file/sidecar replacement.

The Xcode project intentionally uses the sibling local package during development
and links only the three library products. PhotoEvidenceDemo is a standalone example,
not a framework to embed into RawBrowse.
