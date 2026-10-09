import Foundation
@testable import RawBrowse
import Testing

@Suite("Zoom focus point crop mapping")
struct ZoomFocusPointCropTests {
    @Test func uncroppedPointKeepsItsPosition() {
        let point = CGPoint(x: 0.6, y: 0.4)
        #expect(BrowserZoomViewportMath.displayedFocusPoint(point, crop: nil) == point)
    }

    @Test func focusPointMapsIntoOffCenterCrop() throws {
        let crop = RAW9Crop(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
        let point = try #require(BrowserZoomViewportMath.displayedFocusPoint(
            CGPoint(x: 0.625, y: 0.1875), crop: crop,
        ))
        #expect(point == CGPoint(x: 0.75, y: 0.25))
    }

    @Test(arguments: [
        CGPoint(x: 0.125, y: 0.25), CGPoint(x: 0.875, y: 0.25),
        CGPoint(x: 0.5, y: 0.0625), CGPoint(x: 0.5, y: 0.5),
    ])
    func pointsOutsideCropAreHidden(point: CGPoint) {
        let crop = RAW9Crop(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
        #expect(BrowserZoomViewportMath.displayedFocusPoint(point, crop: crop) == nil)
    }

    @Test func cropCornersRemainVisible() {
        let crop = RAW9Crop(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
        #expect(BrowserZoomViewportMath.displayedFocusPoint(
            CGPoint(x: 0.25, y: 0.125), crop: crop,
        ) == .zero)
        #expect(BrowserZoomViewportMath.displayedFocusPoint(
            CGPoint(x: 0.75, y: 0.375), crop: crop,
        ) == CGPoint(x: 1, y: 1))
    }
}
