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
