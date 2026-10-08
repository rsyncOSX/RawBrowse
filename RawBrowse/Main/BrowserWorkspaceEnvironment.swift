import SwiftUI

/// One source for shared dependencies in the browser, AI workspace, and settings.
private struct BrowserWorkspaceEnvironment: ViewModifier {
    let workspace: FileBrowserViewModel

    func body(content: Content) -> some View {
        content
            .environment(workspace)
            .environment(workspace.clip)
            .environment(workspace.zoom)
            .environment(workspace.raw9)
            .environment(workspace.zoom.presentation)
            .environment(workspace.deepReview)
            .environment(workspace.downloads)
            .environment(workspace.settingsModel)
            .environment(workspace.catalog)
            .environment(workspace.contents)
            .environment(workspace.selection)
            .environment(workspace.sidebar)
            .environment(workspace.browserPresentation)
    }
}

extension View {
    func browserWorkspace(_ workspace: FileBrowserViewModel) -> some View {
        modifier(BrowserWorkspaceEnvironment(workspace: workspace))
    }
}
