import SwiftUI

struct RawBrowseCommands: Commands {
    let viewModel: FileBrowserViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Refresh Folder", systemImage: "arrow.clockwise") { viewModel.refreshSelectedFolder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!viewModel.canRefreshSelectedFolder)
            Divider()
            Button("Image Browser") { openWindow(id: "main-window") }
                .keyboardShortcut("1", modifiers: .command)
            Button("AI Workspace") { openWindow(id: "ai-workspace") }
                .keyboardShortcut("2", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About RawBrowse") {
                openWindow(id: "about-window")
            }
        }
    }
}
