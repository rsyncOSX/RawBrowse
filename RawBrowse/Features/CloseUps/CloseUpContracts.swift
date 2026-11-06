import Foundation

/// Host-supplied identity. Revision must change when the source changes.
nonisolated struct CloseUpFrame: Identifiable, Equatable, Sendable {
    let id: URL
    let name: String
    let revision: UUID
}

/// Coordinates are normalized in the orientation-corrected image, origin top-left.
/// Regions are manual inspection choices, never inferred subjects or eye detections.
nonisolated struct CloseUpRegion: Equatable, Sendable {
    var center = CGPoint(x: 0.5, y: 0.5)
    var fraction: Double = 0.25

    var bounds: CGRect {
        let side = min(1, max(0.05, fraction.isFinite ? fraction : 0.25))
        let x = center.x.isFinite ? center.x : 0.5
        let y = center.y.isFinite ? center.y : 0.5
        return CGRect(x: min(1 - side, max(0, x - side / 2)),
                      y: min(1 - side, max(0, y - side / 2)), width: side, height: side)
    }

    func pixelBounds(width: Int, height: Int) -> CGRect {
        let rect = bounds
        return CGRect(x: rect.minX * Double(width), y: rect.minY * Double(height),
                      width: rect.width * Double(width), height: rect.height * Double(height))
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

nonisolated enum CloseUpScaleMode: String, CaseIterable, Sendable {
    case fitRegion, sourcePixels
}

nonisolated struct CloseUpRequest: Equatable, Sendable {
    let frame: CloseUpFrame
    let region: CloseUpRegion
    let mode: CloseUpScaleMode
    let displayScale: Double
}
