import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareForTermination: (@MainActor () async -> String?)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            let failure = await prepareForTermination()
            if let failure {
                let alert = NSAlert()
                alert.messageText = "RawBrowse could not save all edits"
                alert.informativeText = failure
                alert.addButton(withTitle: "Keep RawBrowse Open")
                alert.runModal()
            }
            terminationTask = nil
            sender.reply(toApplicationShouldTerminate: failure == nil)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
