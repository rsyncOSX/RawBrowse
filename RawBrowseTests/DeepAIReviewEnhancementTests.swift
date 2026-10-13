import Foundation
import PhotoAIContracts
@testable import RawBrowse
import Testing

@Suite("Deep Review enhancements")
struct DeepAIReviewEnhancementTests {
    @Test(
        arguments: [
            (DeepAIReviewScope.fast, Array(1 ... 8)),
            (DeepAIReviewScope.automatic, Array(4 ... 15)),
            (DeepAIReviewScope.full, Array(1 ... 15))
        ],
    )
    func `Scope selects the expected candidates`(scope: DeepAIReviewScope, expectedRanks: [Int]) {
        let candidates = (1 ... 15).map { makeCandidate(rank: $0) }

        let selected = RawBrowseDeepAIReviewPipeline.selectedCandidates(
            from: candidates,
            scope: scope,
        )

        #expect(selected.map(\.burstRank) == expectedRanks)
    }

    @Test(
        arguments: [
            ("person", SubjectSegmentationPrompt.face),
            ("bird", SubjectSegmentationPrompt.birdHead),
            ("deer", SubjectSegmentationPrompt.animalHead),
            ("car", SubjectSegmentationPrompt.subject)
        ],
    )
    func `Subject labels choose a specific SAM prompt`(label: String, expectedPrompt: SubjectSegmentationPrompt) {
        let prompts = RawBrowseDeepAIReviewPipeline.promptAttempts(
            preset: .auto,
            subjectLabel: label,
        )

        #expect(prompts.first == expectedPrompt)
    }

    @Test
    func `Review signatures distinguish catalogs revisions and rescanned file IDs`() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appending(path: "a")
        let b = root.appending(path: "b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = BrowserFileItem(url: a.appending(path: "photo.jpg"))
        try Data([1]).write(to: file.url)
        let first = BurstGroupSignature(files: [file], catalog: a)
        let other = BrowserFileItem(url: b.appending(path: "photo.jpg"))
        #expect(first != BurstGroupSignature(files: [other], catalog: b))
        #expect(first != BurstGroupSignature(files: [BrowserFileItem(url: file.url)], catalog: a))
        try Data([1, 2]).write(to: file.url)
        #expect(first != BurstGroupSignature(files: [file], catalog: a))
        #expect(BurstGroupSignature(files: [file], catalog: a) == BurstGroupSignature(files: [file], catalog: nil))
    }

    private func makeCandidate(rank: Int) -> DeepAIReviewInputCandidate {
        DeepAIReviewInputCandidate(
            fileID: UUID(),
            fileName: "photo-\(rank).jpg",
            url: URL(filePath: "/tmp/photo-\(rank).jpg"),
            burstRank: rank,
            normalSharpnessScore: Float(rank),
            subjectLabel: nil,
            normalizedAFPoint: nil,
        )
    }
}
