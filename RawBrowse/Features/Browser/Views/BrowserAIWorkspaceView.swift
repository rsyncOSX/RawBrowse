import SwiftUI

/// Shares the browser selection, but keeps a deep-review snapshot stable during a run.
struct BrowserAIWorkspaceView: View {
    @Environment(SelectionModel.self) private var selection

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(DeepReviewModel.self) private var deepReview

    @Environment(CLIPFeatureModel.self) private var clip

    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @State private var reviewFiles: [BrowserFileItem] = []
    @State private var reviewSignature: BurstGroupSignature?
    @State private var activeTab = "review"

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
            TabView(selection: $activeTab) {
                Tab("Subject Detail", systemImage: "viewfinder", value: "review") {
                    subjectReview
                }
                Tab("Search & Similar", systemImage: "sparkle.magnifyingglass", value: "search") {
                    search
                }
            }
            .padding(16)
        }
        .frame(minWidth: 1120, minHeight: 650)
    }

    private func prepareSubjectReview() {
        reviewFiles = selection.selectedFiles
        reviewSignature = BurstGroupSignature(files: reviewFiles, catalog: contents.selectedFolder?.url)
    }

    private var subjectReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subject Detail").font(.headline)
                    Text("Compare subject sharpness and inspect subject outlines.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(reviewSignature == nil ? "Review Selected Photos" : "Update from Browser Selection") {
                    prepareSubjectReview()
                }
                .disabled(!viewModel.canDeepReviewSelection || deepReview.deepAIReviewController.isRunning)
            }
            if let signature = reviewSignature {
                Text("Reviewing \(reviewFiles.count) photos from your saved selection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                DeepAIReviewSheetView(controller: deepReview.deepAIReviewController,
                                      groupID: signature.hashValue, groupSignature: signature, files: reviewFiles,
                                      onRun: {
                                          await viewModel.startDeepReview(groupID: signature.hashValue,
                                                                          groupSignature: signature, files: reviewFiles)
                                      }, onApply: { result in
                                          if let winner = reviewFiles.first(where: { $0.id == result.recommendedFileID }) {
                                              selection.selectOnlyFile(winner)
                                              openWindow(id: "main-window")
                                          }
                                      }, onClose: { reviewSignature = nil }, isEmbedded: true)
            } else {
                ContentUnavailableView("Ready for Subject Review", systemImage: "viewfinder",
                                       description: Text(deepReview.sam3ModelStatus.isAvailable
                                           ? "Select photos in the browser to compare subject detail and inspect subject outlines."
                                           : "Subject detail review requires a configured SAM 3 model. Manage models in Settings."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var search: some View {
        @Bindable var clip = clip

        return Form {
            Section("Find images by description") {
                TextField("Image description", text: $clip.semanticSearchQuery,
                          prompt: Text("For example: a bird flying over water"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { submitSemanticSearch() }
                Button("Search Images", systemImage: "sparkle.magnifyingglass") {
                    submitSemanticSearch()
                }
                .disabled(!clip.canSearch || clip.semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Search returns up to \(clip.semanticSearchLimit) images using the current Settings.")
                    .foregroundStyle(.secondary)
            }
            Section("Find similar images") {
                Text(selection.selectedFile?.name ?? "Select an image in the browser.")
                Button("Find Similar", systemImage: "photo.stack") {
                    viewModel.startSimilaritySearch()
                    openWindow(id: "main-window")
                }
                .disabled(!viewModel.canFindSimilar)
            }
            Section {
                if !clip.canSearch, !clip.isSearching {
                    Text("Search uses the top-level catalog’s index. Manage the CLIP model and catalog index in Settings.")
                        .foregroundStyle(.secondary)
                }
                if clip.isSearching {
                    ProgressView("Searching…")
                }
                if let error = clip.clipFeatureError {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func submitSemanticSearch() {
        guard clip.canSearch,
              !clip.semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        clip.startSemanticSearch()
        openWindow(id: "main-window")
    }
}
