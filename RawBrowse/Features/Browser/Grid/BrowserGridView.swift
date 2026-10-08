import AppKit
import SwiftUI

struct BrowserGridView: View {
    @Environment(SelectionModel.self) private var selection

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(SettingsModel.self) private var settingsModel

    @Environment(ZoomPresentationState.self) private var zoomPresentation

    @Environment(CLIPFeatureModel.self) private var clip

    @Environment(FileBrowserViewModel.self) private var viewModel
    @FocusState private var isFocused: Bool
    @State private var horizontalThumbnailCount = 1
    @Environment(\.openWindow) private var openWindow

    private let thumbnailMinimumWidth: CGFloat = 150
    private let thumbnailMaximumWidth: CGFloat = 220
    private let gridSpacing: CGFloat = 12
    private let gridPadding: CGFloat = 16

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: thumbnailMinimumWidth, maximum: thumbnailMaximumWidth), spacing: gridSpacing)
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                    ForEach(selection.displayedFiles) { file in
                        BrowserThumbnailCell(
                            file: file,
                            isFocused: selection.selectedFileID == file.id,
                            isSelected: selection.selectedFileIDs.contains(file.id),
                            thumbnailSize: settingsModel.values.thumbnailSizeGrid,
                            displayPath: clip.isShowingSemanticResults ? file.url.path : nil,
                        )
                        .onTapGesture {
                            select(file)
                        }
                        .onTapGesture(count: 2) {
                            viewModel.openZoom(for: file)
                        }
                    }
                }
                .padding(gridPadding)
            }
            .onAppear {
                updateHorizontalThumbnailCount(for: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                updateHorizontalThumbnailCount(for: width)
            }
        }
        .overlay {
            if selection.displayedFiles.isEmpty, !contents.isScanning, !clip.isSearching {
                if clip.isShowingSimilarityResults {
                    ContentUnavailableView(
                        "No Similar Images",
                        systemImage: "photo.stack",
                        description: Text("The index contains no other compatible images."),
                    )
                } else {
                    ContentUnavailableView(
                        clip.semanticSearchQuery.isEmpty ? "No Supported Files" : "No Semantic Matches",
                        systemImage: clip.semanticSearchQuery.isEmpty
                            ? "photo.on.rectangle.angled"
                            : "sparkle.magnifyingglass",
                        description: Text(
                            clip.semanticSearchQuery.isEmpty
                                ? "Choose a folder containing RAW, JPEG, TIFF, or PNG files."
                                : "Try a different description in the AI Workspace.",
                        ),
                    )
                }
            }

            if clip.isSearching {
                ProgressView("Searching…")
                    .padding(14)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Text("\(selection.displayedFiles.count) images")
                Divider().frame(height: 14)
                Text("\(selection.selectedFileIDs.count) selected")
                Spacer()
                if clip.isShowingSemanticResults {
                    Button("Back to Folder", systemImage: "arrow.uturn.backward") {
                        clip.clearSemanticSearchResults()
                    }
                }
                Button("Review Selection", systemImage: "sparkles") {
                    openWindow(id: "ai-workspace")
                }
                .disabled(selection.selectedFileIDs.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(true)
        .onCopyCommand(perform: copyAction)
        .onAppear {
            isFocused = true
        }
        .onChange(of: zoomPresentation.zoomOverlayVisible) { _, isVisible in
            guard !isVisible else { return }
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
        .onKeyPress(.leftArrow) {
            viewModel.navigateSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.navigateSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.navigateSelection(by: -horizontalThumbnailCount)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.navigateSelection(by: horizontalThumbnailCount)
            return .handled
        }
        .onKeyPress(.return) {
            viewModel.openZoom()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "nNpP")) { press in
            switch press.characters {
            case "n", "N":
                viewModel.navigateSelection(by: 1)

            case "p", "P":
                viewModel.navigateSelection(by: -1)

            default:
                break
            }
            return .handled
        }
    }

    private var copyAction: (() -> [NSItemProvider])? {
        let files = selection.selectedFiles
        guard !zoomPresentation.zoomOverlayVisible, !files.isEmpty else { return nil }

        return {
            files.map { NSItemProvider(object: $0.url as NSURL) }
        }
    }

    private func select(_ file: BrowserFileItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            selection.extendFileSelection(to: file)
        } else if modifiers.contains(.command) {
            selection.toggleFileSelection(file)
        } else {
            selection.selectOnlyFile(file)
        }
    }

    private func updateHorizontalThumbnailCount(for width: CGFloat) {
        let availableWidth = max(0, width - (gridPadding * 2))
        let thumbnailCount = Int((availableWidth + gridSpacing) / (thumbnailMinimumWidth + gridSpacing))
        horizontalThumbnailCount = max(1, thumbnailCount)
    }
}
