# Close-ups prototype

Implements the manual-inspection slice of TechDocRawCull's Unified Burst Evidence
plan. In RawBrowse, select images (Command-click or Shift-click), choose Close-ups
in the toolbar, and open Preview to retain the full photograph alongside the
vertical panel. All selected images have a card; scrolling loads cards lazily.
Click a card's overview, drag its blue region, or use its keyboard-accessible center sliders to choose
a manual inspection region. Each frame has an independent region. Fit region
varies magnification; Source pixels shows one oriented source pixel per display
point (not one per physical display pixel). RAW sources use embedded previews,
not developed sensor pixels. Blue overview rectangles show the actual crop.

## Host contract and ownership

`CloseUpFrame` is an immutable source URL/name/revision projection. The host must
change the revision when its source changes. `CloseUpRegion` uses normalized
coordinates on an orientation-corrected image with top-left origin.
`CloseUpRequest` captures frame, region, scale mode and display scale.
`CloseUpRendering` is the replaceable async service; results include bounded crop
and overview artifacts, actual source dimensions/class and displayed bounds.
The contracts contain no browser model, selection state or inference runtime.
`CloseUpRender` is a rendering artifact; CGImage does not enter evidence/domain
snapshots. RawCull integration can supply a different renderer and frame adapter.

`CloseUpModel` owns temporary regions and scale mode; `CloseUpCardModel` owns
loading/error/artifact state and rejects stale or cancelled results by generation.
The panel accepts only those models, frame values, the service, and a close action.
It never changes host selection, ratings, manual winners or durable decisions.
The only browser dependencies live in `BrowserCloseUpAdapter.swift`.

The renderer serializes requests across suspension points and checks cancellation
before decoding and publishing. It uses the existing access leases and preview
cache rather than adding a full-resolution image cache. Returned crop and overview
are capped at 1120 pixels each (280 points × maximum scale 4). Card disappearance
releases artifacts and invalidates pending publication. Source fingerprint checks
reject files changed during loading. Closing preserves temporary regions for the
current selection; reopening prunes choices for deselected sources. A host source
revision change invalidates the old region instead of applying it to a new image. No regions
are persisted across app launches, and selecting a different frame never copies
coordinates from the previous frame.

## Validation and limits

Focused tests cover region bounds/non-finite values, independent choices and late
provider results after newer requests or disappearance. Build the app and run
`RawBrowseTests/CloseUpTests`. Manually inspect landscape/portrait/mirrored sources,
small previews, rapid selection/scrolling, keyboard sliders and narrow windows.
Memory and latency qualification remains required before promoting this prototype
into production burst review; lazy views are not a guaranteed byte budget.

There is no subject detection/matching, sharpness scoring, evidence recommendation,
reference pinning, linked pan/zoom, Combined Review or region persistence in this
slice. Several selected images are inspection inputs, not a claim of comparable
measurements. Those features can extend the contracts when their plan stages are
implemented. No optional AI model is required to use the panel.
