# RawCull fix comparison follow-up

2026-10-16. Apply each update separately and commit after focused validation.

1. Keyboard: anchor the zoom monitor to its own key window, reject sheets/modal input/native controls, and preserve intentional RAW adjustment Command-C/V routing. No accessibility focus queries. Xcode passed ReviewKeyboardScopeTests and ZoomOverlayKeyboardNavigationTests; diff checks passed. Manual Settings/About/sheet/RAW-control keyboard checks remain.
2. Thumbnail publication and request identity: source fingerprint + size identify each request; generation, cancellation and source checks reject stale publication. Disappearance invalidates in-flight results. Xcode passed ThumbnailPresentationTests and FullSizeJPGDiskCacheTests, including delayed old requests, cancellation, source replacement and source switching; diff checks passed.
3. Settings initialization admission: live stores start unread and reject edits/writes until ready; concurrent reads coalesce, retry remains available, and shutdown waits for initialization and saving. Writer-only test stores explicitly start ready. Xcode passed SettingsInitializationTests, FeatureOwnershipTests, RAWPreviewSettingsTests and CLIPFeatureTests; covers pre-load edits/writes, coalesced reads, missing/malformed files, failed-read retry, save failures and termination. Diff checks passed.
4. Reduce Motion: pending.
5. Test cache isolation: pending.
