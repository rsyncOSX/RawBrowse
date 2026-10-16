import SwiftUI

struct FileBrowserView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(BrowserPresentationState.self) private var browserPresentation

    @Environment(CatalogStore.self) private var catalog

    @Environment(SelectionModel.self) private var selection

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(ZoomPresentationState.self) private var zoomPresentation

    @Environment(CLIPFeatureModel.self) private var clip

    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var browserPresentation = browserPresentation

        return ZStack {
            NavigationSplitView {
                BrowserSidebarView()
            } detail: {
                BrowserGridView()
                    .navigationTitle(BrowserNavigationTitle.make(
                        folder: contents.selectedFolder, searchActive: clip.semanticSearchActive,
                        anchorName: clip.similaritySearchAnchorName,
                        resultCount: clip.semanticSearchResults.count, fileCount: contents.files.count,
                    ))
                    .toolbar { toolbarContent }
            }

            if zoomPresentation.zoomOverlayVisible {
                BrowserZoomOverlayView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RAW9SaveFailuresView()
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .fileImporter(isPresented: $browserPresentation.isShowingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard let url = try? result.get() else { return }
            viewModel.addRootFolder(url)
        }
        .alert("Saved Folders", isPresented: Binding(
            get: { catalog.catalogError != nil },
            set: {
                if !$0 {
                    catalog.catalogError = nil
                }
            },
        )) {
            Button("OK") { catalog.catalogError = nil }
            Button("Retry Loading") { Task { await catalog.loadRememberedCatalogs() } }
        } message: {
            Text(catalog.catalogError ?? "Could not restore saved folders.")
        }
        .alert("CLIP Operation Failed", isPresented: clipFailureBinding) {
            Button("OK") {
                clip.clipFeatureError = nil
            }
        } message: {
            Text(clip.clipFeatureError ?? "The CLIP operation could not be completed.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                browserPresentation.isShowingFolderPicker = true
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a folder to the sidebar")
        }

        ToolbarItemGroup {
            Button("Preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                viewModel.openZoom()
            }
            .disabled(selection.selectedFile == nil)
            .help("Preview the selected image (Return)")

            Button("AI Workspace", systemImage: "sparkles.rectangle.stack") {
                openWindow(id: "ai-workspace")
            }
            .help("Review, analyze subjects, and search while browsing")

            if contents.isScanning || contents.isCreatingThumbnails {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var clipFailureBinding: Binding<Bool> {
        Binding {
            clip.clipFeatureError != nil
        } set: { isPresented in
            if !isPresented {
                clip.clipFeatureError = nil
            }
        }
    }
}

private struct RAW9SaveFailuresView: View {
    @Environment(RAW9EditingSession.self) private var raw9

    var body: some View {
        if !raw9.failedSaves.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(raw9.failedSaves.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                    HStack {
                        Label("Unsaved adjustments: \(url.path)", systemImage: "exclamationmark.triangle")
                            .lineLimit(2)
                            .help(raw9.failedSaves[url] ?? "")
                        Spacer()
                        Button("Retry Save") { raw9.retrySave(for: url) }
                    }
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}
