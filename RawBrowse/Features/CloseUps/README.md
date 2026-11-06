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
is saved; Reset view changes only temporary inspection. RAW sources remain embedded
previews. A pinned reference survives selection changes but Show image is offered
only for selected images the host can activate.

Run package tests from PhotoEvidenceKit, and RawBrowseTests/CloseUpTests for source
revision and preference-store integration. No RAW files or XMP sidecars are written.
