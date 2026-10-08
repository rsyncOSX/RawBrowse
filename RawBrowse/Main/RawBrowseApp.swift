import AppKit
import SwiftUI

@main
struct RawBrowseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = FileBrowserViewModel()

    var body: some Scene {
        Window("RawBrowse", id: "main-window") {
            FileBrowserView()
                .browserWorkspace(viewModel)
                .background(.windowBackground)
                .task { await viewModel.loadIfNeeded() }
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            RawBrowseCommands()
        }

        Window("AI Workspace", id: "ai-workspace") {
            BrowserAIWorkspaceView()
                .browserWorkspace(viewModel)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .browserWorkspace(viewModel)
        }

        Window("About RawBrowse", id: "about-window") {
            AboutRawBrowseView()
                .background(.windowBackground)
        }
        .windowResizability(.contentSize)
    }
}
