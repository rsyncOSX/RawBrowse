// Standalone diagnostic, not an application target. See measure-parser-roundtrip.py.
import AppKit
import CryptoKit
import Foundation
#if !PARSER_METRICS
import RawParserKit
#endif

nonisolated struct ProbeImage: Codable, Sendable {
    let name: String
    let start: Double
    let end: Double
    let width: Int
    let height: Int
    let checksum: String
}

@main
struct ParserRoundTripProbe {
    @concurrent static func load(_ url: URL, pixels: Int) async -> ProbeImage {
        let start = ProcessInfo.processInfo.systemUptime
        let image = await RawImageLoader.shared.thumbnail(for: url, maxPixelSize: pixels)
        let end = ProcessInfo.processInfo.systemUptime
        // Hash after the timed API call, using a deterministic RGBA rendering.
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let width = cgImage?.width ?? 0
        let height = cgImage?.height ?? 0
        let checksum: String = autoreleasepool {
            guard let cgImage,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data else { return "failed" }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return SHA256.hash(data: Data(bytes: bytes, count: height * width * 4))
                .map { String(format: "%02x", $0) }.joined()
        }
        return ProbeImage(name: url.lastPathComponent, start: start, end: end,
                          width: width, height: height, checksum: checksum)
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let count = Int(args[2]), let concurrency = Int(args[3]),
              let pixels = Int(args[4]), count > 0, concurrency > 0, pixels > 0 else {
            fatalError("Usage: ParserRoundTripProbe FOLDER COUNT CONCURRENCY PIXELS OUTPUT")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: args[1]),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "arw" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(count)
        let files = Array(urls)
        guard files.count == count else { fatalError("Insufficient files") }
        let start = ProcessInfo.processInfo.systemUptime
        let images = await withTaskGroup(of: ProbeImage.self) { group in
            var next = 0
            for _ in 0 ..< min(concurrency, files.count) {
                let url = files[next]; next += 1
                group.addTask(priority: .utility) { await load(url, pixels: pixels) }
            }
            var results: [ProbeImage] = []
            for await image in group {
                results.append(image)
                if next < files.count {
                    let url = files[next]; next += 1
                    group.addTask(priority: .utility) { await load(url, pixels: pixels) }
                }
            }
            return results.sorted { $0.name < $1.name }
        }
        let end = ProcessInfo.processInfo.systemUptime
        var output: [String: Any] = ["folder": args[1], "count": count,
            "caller_concurrency": concurrency, "pixels": pixels, "batch_ms": (end - start) * 1000,
            "images": try JSONSerialization.jsonObject(with: JSONEncoder().encode(images))]
        #if PARSER_METRICS
        output["intervals"] = ParserExperimentMetrics.snapshot()
        #endif
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[5]))
        guard images.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.checksum != "failed" }) else {
            fatalError("At least one image failed")
        }
    }
}
