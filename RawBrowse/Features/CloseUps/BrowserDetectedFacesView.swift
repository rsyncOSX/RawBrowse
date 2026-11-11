import PhotoAnalysisKit
import PhotoEvidenceContracts
import PhotoEvidenceEngine
import SwiftUI

private nonisolated struct BrowserDetectedCrop: Identifiable, Sendable {
    let id: Int
    let crop: CGImage
    let animalKind: AnimalCloseUpDetector.Kind?
}

private nonisolated enum BrowserFaceStatus: Sendable {
    case ready
    case noFace
    case multipleFaces
    case detailUnavailable
    case unavailable
}

private actor BrowserDetectedFaceLoader {
    static let shared = BrowserDetectedFaceLoader()
    private let analyzer = FaceEvidenceAnalyzer()

    func load(_ url: URL) async throws -> (faces: [BrowserDetectedCrop], animals: [BrowserDetectedCrop]?, status: BrowserFaceStatus) {
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
        let faces: [BrowserDetectedCrop] = (result?.faces ?? []).compactMap { face in
            let target = DetectedFaceCloseUp(id: face.id, normalizedBounds: face.normalizedBounds,
                                             localDetail: face.localDetail)
            guard let crop = DetectedFaceRasterizer.crop(target, from: preview) else { return nil }
            return BrowserDetectedCrop(id: face.id, crop: crop, animalKind: nil)
        }
        let animals: [BrowserDetectedCrop]? = animalRegions.map { regions in
            regions.enumerated().compactMap { index, region in
                let target = DetectedFaceCloseUp(id: index, normalizedBounds: region.bounds, localDetail: nil)
                guard let crop = DetectedFaceRasterizer.crop(target, from: preview) else { return nil }
                return BrowserDetectedCrop(id: index, crop: crop, animalKind: region.kind)
            }
        }
        let status: BrowserFaceStatus = switch result?.faces.count {
        case nil:
            .unavailable
        case 0:
            .noFace
        case 1:
            if let detail = result?.faces.first?.localDetail, detail.isFinite, detail > 0 {
                .ready
            } else {
                .detailUnavailable
            }
        default:
            .multipleFaces
        }
        return (faces, animals, status)
    }
}

private struct BrowserDetectedFacesView: View {
    let url: URL

    private enum State {
        case loading
        case loaded(faces: [BrowserDetectedCrop], animals: [BrowserDetectedCrop]?, status: BrowserFaceStatus)
        case unavailable
    }

    @State private var state = State.loading
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .loading:
                Label("Checking…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.yellow)

            case let .loaded(faces, animals, status):
                if !faces.isEmpty || animals?.isEmpty == false {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(faces) { face in
                                cropTile(face)
                            }
                            ForEach(animals ?? []) { animal in
                                cropTile(animal)
                            }
                        }
                    }
                }
                HStack {
                    faceStatusLabel(status)
                    if status == .unavailable || animals == nil {
                        Button("Retry") { retry += 1 }.controlSize(.small)
                    }
                }
                if animals == nil {
                    Text("Animal close-ups unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .unavailable:
                HStack {
                    faceStatusLabel(.unavailable)
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
                state = .loaded(faces: detections.faces, animals: detections.animals, status: detections.status)
            } catch {
                guard !Task.isCancelled else { return }
                state = .unavailable
            }
        }
    }

    private func cropTile(_ detection: BrowserDetectedCrop) -> some View {
        let label: LocalizedStringKey = switch detection.animalKind {
        case .head: "Animal head"
        case .eye: "Animal eye"
        case nil: "Detected face \(detection.id + 1)"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Image(detection.crop, scale: 1, label: Text(label))
                .resizable()
                .scaledToFit()
                .frame(width: 118, height: 92)
                .background(.black)
            if detection.animalKind != nil {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func faceStatusLabel(_ status: BrowserFaceStatus) -> some View {
        let title: LocalizedStringKey = switch status {
        case .ready: "Face ready"
        case .noFace: "No face detected"
        case .multipleFaces: "Multiple faces detected"
        case .detailUnavailable: "Face detail unavailable"
        case .unavailable: "Face check unavailable"
        }
        return Label(title, systemImage: status == .ready ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(status == .ready ? Color.green : Color.red)
            .help("Face evidence for this frame, measured from the browser preview.")
    }
}

struct BrowserDetectedFacesSection: View {
    let files: [BrowserCloseUpFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                                BrowserDetectedFacesView(url: file.url)
                                    .id(file.refreshRevision)
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
