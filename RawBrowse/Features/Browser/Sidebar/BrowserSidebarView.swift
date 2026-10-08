import SwiftUI

struct BrowserSidebarView: View {
    @Environment(BrowserPresentationState.self) private var browserPresentation

    @Environment(SidebarPresentationModel.self) private var sidebar

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(CatalogStore.self) private var catalog

    @Environment(FileBrowserViewModel.self) private var viewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var browserPresentation = browserPresentation

        return List(selection: selectedFolderBinding) {
            Section("Catalogs") {
                ForEach(sidebar.visibleSidebarFolders) { folder in
                    FolderOutlineRow(folder: folder, isRootCatalog: catalog.rootFolders.contains { $0.id == folder.id })
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .focused($isFocused)
        .simultaneousGesture(
            TapGesture().onEnded {
                if !isFocused {
                    isFocused = true
                }
            },
        )
        .onMoveCommand { direction in
            switch direction {
            case .up:
                moveSelection(by: -1)

            case .down:
                moveSelection(by: 1)

            case .left:
                sidebar.collapseSelectedSidebarFolder(contents.selectedFolder, enabled: contents.isSidebarSelectionEnabled)

            case .right:
                sidebar.expandSelectedSidebarFolder(contents.selectedFolder, enabled: contents.isSidebarSelectionEnabled)

            @unknown default:
                break
            }
        }
        .overlay {
            if catalog.rootFolders.isEmpty {
                ContentUnavailableView(
                    "No Folders",
                    systemImage: "folder",
                    description: Text("Please add a folder."),
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarIndexPanel()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    browserPresentation.isShowingClearCatalogConfirmation = true
                } label: {
                    Label("Clear Remembered Catalogs", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .disabled(catalog.rootFolders.isEmpty)
                .help("Clear remembered catalogs")
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.bar)
        }
        .confirmationDialog(
            "Clear remembered catalogs?",
            isPresented: $browserPresentation.isShowingClearCatalogConfirmation,
        ) {
            Button("Clear Catalogs", role: .destructive) {
                Task {
                    await viewModel.clearRememberedCatalogs()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved catalog entries from the sidebar. It does not delete any files.")
        }
    }

    private func moveSelection(by offset: Int) {
        guard let folder = sidebar.destination(by: offset, selectedFolder: contents.selectedFolder,
                                               enabled: contents.isSidebarSelectionEnabled) else { return }
        viewModel.selectFolder(folder)
    }

    private var selectedFolderBinding: Binding<BrowserFolderItem.ID?> {
        Binding {
            contents.selectedFolder?.id
        } set: { id in
            guard let id, contents.isSidebarSelectionEnabled else { return }
            if let folder = catalog.folder(for: id) {
                viewModel.selectFolder(folder)
            }
        }
    }
}

private struct SidebarIndexPanel: View {
    @Environment(BrowserContentsModel.self) private var contents

    @Environment(CLIPFeatureModel.self) private var clip
    @Environment(FileBrowserViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if clip.isIndexing {
                Button(role: .cancel) {
                    clip.cancelIndexing()
                } label: {
                    Label("Cancel Indexing", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    clip.startIndexingSelectedFolder()
                } label: {
                    Label(indexButtonTitle, systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!clip.canIndexSelectedFolder)
                .help(indexButtonHelp)
            }

            if clip.isIndexing {
                indexingProgress
            } else {
                indexStatus
            }
            if clip.isShowingSimilarityResults {
                Button {
                    clip.clearSemanticSearchResults()
                } label: {
                    Label("Clear Similarity", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Return to the selected folder")
            }

            Button {
                viewModel.startSimilaritySearch()
            } label: {
                Label("Find Similar", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canFindSimilar)
            .help("Rank the indexed folder by similarity to the selected image")
        }
        .padding(10)
        .background(.bar)
    }

    private var indexingProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: completed, total: total)
            Text(indexingProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var indexStatus: some View {
        switch clip.clipIndexStatus {
        case .noFolderSelected:
            statusLabel("Select a folder to check its index", systemImage: "folder", color: .secondary)

        case .modelRequired:
            statusLabel("Set and verify a CLIP model in Settings", systemImage: "exclamationmark.triangle", color: .orange)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Validating index…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .notFound:
            statusLabel("No index found", systemImage: "circle.dashed", color: .secondary)

        case let .valid(_, indexed, updatedAt):
            VStack(alignment: .leading, spacing: 2) {
                statusLabel("Valid index · \(indexed) images", systemImage: "checkmark.circle.fill", color: .green)
                updatedLabel(updatedAt)
            }

        case let .needsUpdate(_, indexed, missing, changed, removed, updatedAt):
            VStack(alignment: .leading, spacing: 3) {
                statusLabel("Update recommended", systemImage: "exclamationmark.triangle.fill", color: .orange)
                Text(updateDetails(indexed: indexed, missing: missing, changed: changed, removed: removed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                updatedLabel(updatedAt)
            }

        case let .invalid(_, reason):
            VStack(alignment: .leading, spacing: 2) {
                statusLabel("Invalid index", systemImage: "xmark.octagon.fill", color: .red)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(reason)
            }
        }
    }

    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updatedLabel(_ date: Date) -> some View {
        Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var indexButtonTitle: String {
        clip.clipIndexStatus.recommendsUpdate ? "Update Index" : "Index Selected Folder"
    }

    private var indexButtonHelp: String {
        if !clip.clipModelStatus.isAvailable {
            return "Choose and verify a CLIP model in Settings"
        }
        guard let folder = contents.selectedFolder else {
            return "Select a folder to index"
        }
        return "Recursively synchronize the CLIP index in \(folder.url.path)"
    }

    private var completed: Double {
        Double(clip.indexingProgress?.completed ?? 0)
    }

    private var total: Double {
        Double(max(clip.indexingProgress?.total ?? 1, 1))
    }

    private var indexingProgressText: String {
        guard let progress = clip.indexingProgress else { return "Discovering images…" }
        let count = "Indexing \(progress.completed) of \(progress.total)"
        return progress.currentFileName.map { "\(count) · \($0)" } ?? count
    }

    private func updateDetails(indexed: Int, missing: Int, changed: Int, removed: Int) -> String {
        var changes: [String] = []
        if missing > 0 {
            changes.append("\(missing) missing")
        }
        if changed > 0 {
            changes.append("\(changed) changed")
        }
        if removed > 0 {
            changes.append("\(removed) removed")
        }
        return "\(indexed) indexed · \(changes.joined(separator: ", "))."
    }
}
