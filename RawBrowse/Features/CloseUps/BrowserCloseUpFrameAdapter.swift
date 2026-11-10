import Foundation
import ImageIO
import RawParserKit
import PhotoEvidenceContracts

/// Source metadata is read off the UI actor and protected by catalog access.
/// Revisions are stable across launches, unlike BrowserFileItem's session UUID.
enum BrowserCloseUpFrameAdapter {
    @concurrent static func frames(for files: [BrowserFileItem]) async -> [CloseUpFrame] {
        var result: [CloseUpFrame] = []
        for file in files {
            guard !Task.isCancelled else { return [] }
            let access = await CatalogAccess.shared.lease(for: file.url)
            let revision = ImageSourceFingerprint.key(for: file.url)
            withExtendedLifetime(access) {}
            result.append(CloseUpFrame(id: file.url, name: file.name, revision: revision))
        }
        return result
    }
}

/// Camera AF metadata uses sensor coordinates; crop regions use oriented coordinates.
nonisolated enum BrowserCloseUpAFPoint {
    @concurrent static func load(for frames: [CloseUpFrame]) async throws -> [URL: CloseUpAFPointAvailability] {
        var result: [URL: CloseUpAFPointAvailability] = [:]
        for frame in frames {
            try Task.checkCancellation()
            let access = await CatalogAccess.shared.lease(for: frame.id)
            defer { withExtendedLifetime(access) {} }
            let metadata = await RawParserKit.RawImageLoader.shared.metadata(for: frame.id)
            let point = metadata?.focusPoint.map {
                CGPoint(x: $0.normalizedX, y: $0.normalizedY)
            }
            result[frame.id] = availability(frame: frame, point: point, orientation: orientation(for: frame.id))
        }
        try Task.checkCancellation()
        return result
    }

    static func orientation(for url: URL) -> UInt32? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? (tiff?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value ?? 1
    }

    static func availability(frame: CloseUpFrame, point: CGPoint?, orientation: UInt32?) -> CloseUpAFPointAvailability {
        guard let point else { return .unavailable(reason: "No usable recorded AF point is available.") }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else {
            return .unavailable(reason: "Recorded AF coordinates are invalid.")
        }
        guard let orientation, (1...8).contains(orientation) else {
            return .unavailable(reason: "Image orientation is unavailable for AF placement.")
        }
        let x = point.x, y = point.y
        let center: CGPoint
        switch orientation {
        case 2: center = CGPoint(x: 1 - x, y: y)
        case 3: center = CGPoint(x: 1 - x, y: 1 - y)
        case 4: center = CGPoint(x: x, y: 1 - y)
        case 5: center = CGPoint(x: y, y: x)
        case 6: center = CGPoint(x: 1 - y, y: x)
        case 7: center = CGPoint(x: 1 - y, y: 1 - x)
        case 8: center = CGPoint(x: y, y: 1 - x)
        default: center = point
        }
        guard let target = CloseUpAFPoint(frame: frame, center: center) else {
            return .unavailable(reason: "Recorded AF coordinates are invalid.")
        }
        return .available(target)
    }
}
