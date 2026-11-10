import PhotoAnalysisKit
import PhotoEvidenceContracts
import PhotoEvidenceEngine
import SwiftUI

private nonisolated struct BrowserDetectedCrop: Identifiable, Sendable {
    let evidence: DetectedFaceCloseUp
    let animalKind: AnimalCloseUpDetector.Kind?
    let crop: CGImage
    var id: Int {
        evidence.id
    }
}

private actor BrowserDetectedFaceLoader {
    static let shared = BrowserDetectedFaceLoader()
    private let analyzer = FaceEvidenceAnalyzer()

    func load(_ url: URL) async throws -> (faces: [BrowserDetectedCrop]?, animals: [BrowserDetectedCrop]?) {
        let access = await CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        try Task.checkCancellation()
        let revision = ImageSourceFingerprint.key(for: url)
        guard let preview = await BrowserImageLoader.shared.previewImage(for: url, maxPixelSize: 2048) else {
            throw CloseUpRenderError.unavailable
        }

        let result = try? await analyzer.analyze(preview)
        try Task.checkCancellation()
        let animalRegions = try? AnimalCloseUpDetector.regions(in: preview)
        try Task.checkCancellation()
        guard ImageSourceFingerprint.key(for: url) == revision else {
            throw CloseUpRenderError.sourceChanged
        }
        let faces: [BrowserDetectedCrop]? = result?.faces.compactMap { face in
            let target = DetectedFaceCloseUp(id: face.id, normalizedBounds: face.normalizedBounds,
                                             localDetail: face.localDetail)
            guard let crop = DetectedFaceRasterizer.crop(target, from: preview) else { return nil }
            return BrowserDetectedCrop(evidence: target, animalKind: nil, crop: crop)
        }
        let animals: [BrowserDetectedCrop]? = animalRegions.map { regions in
            regions.enumerated().compactMap { index, region in
                let target = DetectedFaceCloseUp(id: index, normalizedBounds: region.bounds, localDetail: nil)
                guard let crop = DetectedFaceRasterizer.crop(target, from: preview) else { return nil }
                return BrowserDetectedCrop(evidence: target, animalKind: region.kind, crop: crop)
            }
        }
        return (faces, animals)
    }
}

private struct BrowserDetectedFacesView: View {
    let url: URL

    private enum State {
        case loading
        case loaded(faces: [BrowserDetectedCrop]?, animals: [BrowserDetectedCrop]?)
        case unavailable
    }

    @State private var state = State.loading
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .loading:
                ProgressView().controlSize(.small).accessibilityLabel("Detecting faces and animal landmarks")

            case let .loaded(faces, animals):
                if faces?.isEmpty == true && animals?.isEmpty == true {
                    Text("No faces or animal landmarks detected").font(.caption).foregroundStyle(.secondary)
                } else if faces?.isEmpty == false || animals?.isEmpty == false {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(faces ?? []) { face in
                                cropTile(face)
                            }
                            ForEach(animals ?? []) { animal in
                                cropTile(animal)
                            }
                        }
                    }
                }
                if faces == nil || animals == nil {
                    HStack {
                        detectionFailure(faces: faces, animals: animals)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }.controlSize(.small)
                    }
                }

            case .unavailable:
                HStack {
                    Text("Detected close-ups unavailable").font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }.controlSize(.small)
                }
            }
        }
        .task(id: retry) {
            state = .loading
            do {
                try await Task.sleep(for: .milliseconds(150))
                let detections = try await BrowserDetectedFaceLoader.shared.load(url)
                try Task.checkCancellation()
                state = .loaded(faces: detections.faces, animals: detections.animals)
            } catch {
                guard !Task.isCancelled else { return }
                state = .unavailable
            }
        }
    }

    private func detectionFailure(faces: [BrowserDetectedCrop]?, animals: [BrowserDetectedCrop]?) -> Text {
        if faces == nil, animals == nil { return Text("Detected close-ups unavailable") }
        if faces == nil { return Text("Human face detection unavailable") }
        return Text("Animal close-ups unavailable")
    }

    private func cropTile(_ face: BrowserDetectedCrop) -> some View {
        let label: LocalizedStringResource = switch face.animalKind {
        case .head: "Animal head"
        case .eye: "Animal eye"
        case nil: "Detected face \(face.id + 1)"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Image(decorative: face.crop, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: 118, height: 92)
                .background(.black)
                .accessibilityLabel(Text(label))
            Text(label)
            if face.animalKind == nil, let detail = face.evidence.localDetail {
                Text("Detail: \(detail.formatted(.number.precision(.significantDigits(3))))")
                    .help("Preview detail measurement for comparing similar captures of the same face.")
            } else if face.animalKind == nil {
                Text("Detail unavailable")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct BrowserDetectedFacesSection: View {
    let files: [BrowserCloseUpFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detected faces and animal landmarks · browser preview")
                .font(.caption.weight(.semibold))
            if files.count > 1 {
                ScrollViewReader { proxy in
                    Menu("Jump to image (\(files.count))") {
                        ForEach(files, id: \.url) { file in
                            Button(file.url.lastPathComponent) {
                                proxy.scrollTo(file.url, anchor: .top)
                            }
                        }
                    }
                    .controlSize(.small)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(files, id: \.url) { file in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.url.lastPathComponent)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .help(file.url.lastPathComponent)
                                    BrowserDetectedFacesView(url: file.url)
                                        .id(file.refreshRevision)
                                }
                                .id(file.url)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            } else if let file = files.first {
                BrowserDetectedFacesView(url: file.url)
                    .id(file.refreshRevision)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
