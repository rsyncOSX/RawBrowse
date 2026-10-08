import CoreGraphics
import Observation

@Observable @MainActor
final class ZoomPresentationState {
    var zoomOverlayVisible = false
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var isZoomMetadataVisible = true
    var isZoomMetadataCollapsed = false
    var zoomMetadataOffset: CGSize = .zero
    var isZoomFocusPointVisible = false
    var zoomLaunchContext: BrowserZoomLaunchContext = .default
    var zoomOverlayNavigationAxis: ZoomOverlayNavigationAxis = .horizontal

    func resetZoomInterfaceState() {
        zoomScale = 1.0
        zoomOffset = .zero
        isZoomMetadataCollapsed = false
        zoomMetadataOffset = .zero
        isZoomFocusPointVisible = false
        zoomLaunchContext = .default
    }
}
