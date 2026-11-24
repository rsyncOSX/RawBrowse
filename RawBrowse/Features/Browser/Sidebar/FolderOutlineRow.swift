import SwiftUI

struct FolderOutlineRow: View {
    @Environment(SidebarPresentationModel.self) private var sidebar

    @Environment(BrowserContentsModel.self) private var contents

    @Environment(CatalogStore.self) private var catalog

    @Environment(FileBrowserViewModel.self) private var viewModel
    let folder: BrowserFolderItem
    let isRootCatalog: Bool

    var body: some View {
        HStack(spacing: 4) {
            if shouldShowDisclosure {
                Button {
                    sidebar.setFolder(folder, expanded: !sidebar.isFolderExpanded(folder))
                } label: {
                    Image(systemName: sidebar.isFolderExpanded(folder) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .disabled(!contents.isSidebarSelectionEnabled)
                .accessibilityLabel(sidebar.isFolderExpanded(folder) ? "Collapse \(folder.name)" : "Expand \(folder.name)")
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            folderLabel
        }
        .padding(.leading, CGFloat(sidebar.depthByID[folder.id] ?? 0) * 16)
        .tag(folder.id)
        .selectionDisabled(!contents.isSidebarSelectionEnabled)
        .contextMenu { rootCatalogDeleteButton }
    }

    private var shouldShowDisclosure: Bool {
        !catalog.hasLoadedChildren(for: folder) || !catalog.children(of: folder).isEmpty
    }

    private var folderLabel: some View {
        Label {
            HStack {
                Text(displayName)
                    .lineLimit(1)
                Spacer()
                if let imageCountText {
                    Text(imageCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: folder.supportedFileCount > 0 ? "folder.fill" : "folder")
                .foregroundStyle(folder.supportedFileCount > 0 ? .blue : .secondary)
        }
        .badge(clipIndexBadge)
    }

    private var displayName: String {
        guard isRootCatalog, !catalog.children(of: folder).isEmpty else { return folder.name }
        return folder.name
    }

    private var imageCountText: String? {
        guard folder.supportedFileCount > 0 else { return nil }
        return "\(folder.supportedFileCount)"
    }

    private var clipIndexBadge: Text? {
        guard folder.hasCLIPIndex else { return nil }
        return Text("CLIP", comment: "Sidebar badge indicating that a folder contains a CLIP index.")
    }

    @ViewBuilder
    private var rootCatalogDeleteButton: some View {
        if isRootCatalog {
            Button("Delete Catalog from Sidebar", role: .destructive) {
                Task {
                    await viewModel.removeRootCatalog(folder)
                }
            }
        }
    }
}
