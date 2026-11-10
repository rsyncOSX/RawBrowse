import SwiftUI

/// Shares the browser selection, but keeps a deep-review snapshot stable during a run.
struct BrowserAIWorkspaceView: View {
    @Environment(SelectionModel.self) private var selection

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(DeepReviewModel.self) private var deepReview

    @Environment(CLIPFeatureModel.self) private var clip

    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var reviewFiles: [BrowserFileItem] = []
    @State private var reviewSignature: BurstGroupSignature?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Workspace").font(.title2.bold())
                    Text("Select images in the browser, then choose an analysis below.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(selection.selectedFileIDs.count) selected").monospacedDigit()
                Button("Show Browser", systemImage: "photo.on.rectangle") {
                    openWindow(id: "main-window")
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    search
                    Divider()
                    subjectReview
                }
                .padding(20)
            }
        }
        .frame(minWidth: 1120, minHeight: 650)
    }

    private var subjectReview: some View {
        let files = reviewSignature == nil ? selection.selectedFiles : reviewFiles
        let signature = BurstGroupSignature(files: files, catalog: contents.selectedFolder?.url)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Subject Detail").font(.headline)
            Text("Compare subject sharpness and inspect subject outlines.")
                .foregroundStyle(.secondary)
            if reviewSignature != nil {
                Text("Reviewing \(reviewFiles.count) photos from your saved selection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DeepAIReviewSheetView(
                controller: deepReview.deepAIReviewController,
                groupID: signature.hashValue,
                groupSignature: signature,
                files: files,
                onRun: {
                    guard viewModel.canDeepReviewSelection else { return }
                    let selectedFiles = selection.selectedFiles
                    let selectedSignature = BurstGroupSignature(files: selectedFiles, catalog: contents.selectedFolder?.url)
                    reviewFiles = selectedFiles
                    reviewSignature = selectedSignature
                    await viewModel.startDeepReview(groupID: selectedSignature.hashValue,
                                                    groupSignature: selectedSignature, files: selectedFiles)
                },
                onClose: {
                    reviewSignature = nil
                    reviewFiles = []
                },
                isEmbedded: true,
                canRunSelection: viewModel.canDeepReviewSelection,
            )
            .frame(height: 420)
        }
    }

    private var search: some View {
        @Bindable var clip = clip

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                GroupBox("Find images by description") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Image description", text: $clip.semanticSearchQuery,
                                  prompt: Text("For example: a bird flying over water"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitSemanticSearch() }
                        Button("Search Images", systemImage: "sparkle.magnifyingglass") {
                            submitSemanticSearch()
                        }
                        .disabled(!clip.canSearch || clip.semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(searchAvailabilityMessage)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                GroupBox("Find similar images") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selection.selectedFile?.name ?? "Select an image in the browser.")
                            .lineLimit(1)
                        Button("Find Similar", systemImage: "photo.stack") {
                            viewModel.startSimilaritySearch()
                            showSearchInBrowser()
                        }
                        .disabled(!viewModel.canFindSimilar)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 300)
            }
            if let error = clip.clipFeatureError {
                Text(error).foregroundStyle(.orange)
            }
        }
    }

    private var searchAvailabilityMessage: LocalizedStringKey {
        if clip.canSearch {
            if clip.semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter an image description to search."
            }
            return "Search returns up to \(clip.semanticSearchLimit) images using the current Settings."
        }
        if clip.isSearching { return "Searching…" }
        if clip.isIndexing { return "Wait for indexing to finish before searching." }

        switch clip.clipModelStatus {
        case .notConfigured:
            return "Choose and verify a CLIP model in Settings → AI."
        case .missing:
            return "The selected CLIP model is missing. Choose a model in Settings → AI."
        case .invalid:
            return "The selected CLIP model could not be verified. Check Settings → AI."
        case .checking:
            return "Checking the CLIP model…"
        case .available:
            break
        }

        switch clip.clipIndexStatus {
        case .noFolderSelected:
            return "Select a catalog in the browser to search."
        case .checking:
            return "Checking the catalog index…"
        case .notFound:
            return "Index the top-level catalog in Settings → AI to enable search."
        case .invalid:
            return "Update the top-level catalog’s index in Settings → AI to enable search."
        case .modelRequired, .valid, .needsUpdate:
            return "Search is temporarily unavailable."
        }
    }

    private func submitSemanticSearch() {
        guard clip.canSearch,
              !clip.semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        clip.startSemanticSearch()
        showSearchInBrowser()
    }

    private func showSearchInBrowser() {
        guard clip.isSearching else { return }
        openWindow(id: "main-window")
        dismissWindow(id: "ai-workspace")
    }
}
