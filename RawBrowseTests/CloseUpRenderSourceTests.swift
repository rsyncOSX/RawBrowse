import CoreGraphics
import Foundation
import Testing
import PhotoEvidenceContracts
import PhotoEvidenceEngine
@testable import RawBrowse

@Suite("Close-ups decoded source integration") @MainActor
struct CloseUpRenderSourceTests {
    @Test func cancelledCapabilityProbeDoesNotDisableRAW9ForLaterEdits() async throws {
        let probe = CancelledCapabilityProbe()
        let planner = BrowserCloseUpSourcePlanner(supportsRAW9: { _ in await probe.check() })
        let file = BrowserCloseUpFile(url: URL(filePath: "/fixture/cancelled.ARW"), refreshRevision: UUID())
        let inputs = BrowserCloseUpRenderingInputs(files: [file], reference: nil,
            developRAW: true, bitDepth: .sixteenBit, liveAdjustments: [file.url: RAW9Adjustments()])
        let cancelled = Task { try await planner.prepare(inputs) }
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled preparation must not publish a plan")
        } catch is CancellationError {
            // The next preparation must probe again rather than reuse false.
        }
        var edited = RAW9Adjustments(); edited.exposure = 2
        let updated = BrowserCloseUpRenderingInputs(files: [file], reference: nil,
            developRAW: true, bitDepth: .sixteenBit, liveAdjustments: [file.url: edited])
        let plan = try #require(try await planner.prepare(updated).first)
        #expect(plan.backend == .raw9)
        #expect(plan.adjustments == edited)
        #expect(await probe.calls == 2)
    }

    @Test func selectedSourceAppliesToCandidatesAndDeselectedReference() async throws {
        let planner = BrowserCloseUpSourcePlanner(supportsRAW9: { $0.lastPathComponent == "a.ARW" })
        let a = BrowserCloseUpFile(url: URL(filePath: "/fixture/a.ARW"), refreshRevision: UUID())
        let b = BrowserCloseUpFile(url: URL(filePath: "/fixture/b.NEF"), refreshRevision: UUID())
        let original = BrowserCloseUpFile(url: URL(filePath: "/fixture/c.jpg"), refreshRevision: UUID())
        let reference = CloseUpFrame(id: a.url, name: "a.ARW", revision: "old")
        var edited = RAW9Adjustments(); edited.exposure = 2
        let plans = try await planner.prepare(BrowserCloseUpRenderingInputs(files: [b, original], reference: reference,
            developRAW: true, bitDepth: .sixteenBit, liveAdjustments: [a.url: edited]))
        #expect(plans.map(\.backend) == [.raw, .original, .raw9])
        #expect(plans[2].adjustments == edited)
        #expect(plans[0].adjustments == nil)
        let jpg = try await planner.prepare(BrowserCloseUpRenderingInputs(files: [b, original], reference: reference,
            developRAW: false, bitDepth: .sixteenBit, liveAdjustments: [a.url: edited]))
        #expect(jpg.map(\.backend) == [.embedded, .original, .embedded])
        #expect(jpg[2].frame.revision == plans[2].frame.revision)
    }

    @Test func raw9RevisionIncludesSettingsDepthAndSidecarVersion() throws {
        let frame = CloseUpFrame(id: URL(filePath: "/fixture/a.ARW"), name: "a", revision: "same-file")
        let base = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .eightBit, adjustments: RAW9Adjustments())
        var edited = RAW9Adjustments(); edited.exposure = 1
        let changed = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .eightBit, adjustments: edited)
        let deep = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .sixteenBit, adjustments: RAW9Adjustments())
        #expect(base.source != changed.source)
        #expect(base.source != deep.source)
        #expect(base.frame == changed.frame)
        let diskA = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .eightBit, sidecarRevision: "disk-a")
        let diskB = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .eightBit, sidecarRevision: "disk-b")
        #expect(diskA.source != diskB.source)
    }

    @Test func snapshotReadsDoNotPrepareOtherFilesOrPersistDecisions() async throws {
        let a = URL(filePath: "/fixture/a.ARW"), b = URL(filePath: "/fixture/b.ARW")
        let session = RAW9EditingSession(load: { _ in RAW9Adjustments() }, save: { _, _ in })
        _ = session.prepare(for: a)
        try await session.restore(for: a, initialAdjustments: RAW9Adjustments())
        var edited = RAW9Adjustments(); edited.exposure = 2
        session.raw9Adjustments = edited
        #expect(session.adjustmentsSnapshot(for: a) == edited)
        #expect(session.adjustmentsSnapshot(for: b) == nil)
        #expect(session.isEditing(a))
        await session.finishSaving()
    }

    @Test func cropAndStraighteningMapCanonicalCoordinates() throws {
        var adjustments = RAW9Adjustments()
        adjustments.crop = RAW9Crop(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
        adjustments.straightenAngle = 5
        let size = CGSize(width: 1000, height: 1600)
        let transform = BrowserCloseUpDecodedSource.coordinateTransform(adjustments: adjustments, renderedSize: size)
        let point = CGPoint(x: 0.5, y: 0.6)
        let straight = RAW9Straightening.displayedPoint(point, imageSize: CGSize(width: 2000, height: 2000), degrees: 5)
        let mapped = transform.point(point)
        #expect(abs(mapped.x - (straight.x - 0.25) / 0.5) < 0.000001)
        #expect(abs(mapped.y - (straight.y - 0.1) / 0.8) < 0.000001)
        let restored = try #require(transform.inversePoint(mapped))
        #expect(abs(restored.x - point.x) < 0.000001)
        #expect(abs(restored.y - point.y) < 0.000001)
    }

    @Test func rendererUsesExactFrozenPlanAndEchoesSource() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "a.ARW")
        try Data([1, 2, 3]).write(to: url)
        let frame = try #require(await BrowserCloseUpFrameAdapter.frames(for: [BrowserFileItem(url: url)]).first)
        var adjustments = RAW9Adjustments(); adjustments.exposure = 2
        let plan = try BrowserCloseUpRenderPlan(frame: frame, backend: .raw9, bitDepth: .sixteenBit, adjustments: adjustments)
        let probe = DecodingPlanProbe()
        let renderer = BrowserCloseUpRenderer(loadSource: { plan in try await probe.load(plan) })
        await renderer.configure([plan])
        let result = try await renderer.render(CloseUpRequest(frame: frame, region: CloseUpRegion(),
            mode: .sourcePixels, displayScale: 2, renderSource: plan.source))
        #expect(result.renderSource == plan.source)
        #expect(result.sourceLabel == "RAW 9 fixture")
        #expect(await probe.lastPlan == plan)
    }
}

private actor CancelledCapabilityProbe {
    private(set) var calls = 0

    func check() -> Bool {
        calls += 1
        if calls == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
            return false
        }
        return true
    }
}

private actor DecodingPlanProbe {
    private(set) var lastPlan: BrowserCloseUpRenderPlan?
    func load(_ plan: BrowserCloseUpRenderPlan) throws -> BrowserCloseUpDecodedImage {
        lastPlan = plan
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return BrowserCloseUpDecodedImage(image: try #require(context.makeImage()), label: "RAW 9 fixture")
    }
}
