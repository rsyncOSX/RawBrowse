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
    @State private var isExportQueuePresented = false
    private let exports = RAW9ExportQueue.shared

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
            VStack(spacing: 0) {
                FolderAccessFailureView()
                RAW9SaveFailuresView()
                RAW9CompatibilityStatusView()
            }
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
            Button("Exports (\(exports.outstandingCount))", systemImage: exports.failures.isEmpty ? "square.and.arrow.up" : "exclamationmark.triangle") {
                isExportQueuePresented = true
            }
            .popover(isPresented: $isExportQueuePresented) { RAW9ExportQueueView(queue: exports) }
            Button("Refresh Folder", systemImage: "arrow.clockwise") { viewModel.refreshSelectedFolder() }
                .disabled(!viewModel.canRefreshSelectedFolder)
                .help("Rescan the selected folder for disk changes (Shift-Command-R)")
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

private struct FolderAccessFailureView: View {
    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(BrowserPresentationState.self) private var presentation

    var body: some View {
        if let failure = viewModel.folderAccessFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") { viewModel.retryFolderAccess() }
                    Button("Add Folder Again") {
                        viewModel.dismissFolderAccessFailure()
                        presentation.isShowingFolderPicker = true
                    }
                    Button("Dismiss") { viewModel.dismissFolderAccessFailure() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

private struct RAW9CompatibilityStatusView: View {
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        if catalog.isScanningRAW9Compatibility {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Label("Searching for RAW 9 compatibility…", systemImage: "figure.run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(8)
        }
    }
}
