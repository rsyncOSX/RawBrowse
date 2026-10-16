import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareForTermination: (@MainActor () async -> String?)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            let exports = RAW9ExportQueue.shared
            if exports.outstandingCount > 0 {
                let alert = NSAlert()
                alert.messageText = "Exports are still running"
                alert.informativeText = "\(exports.outstandingCount) export(s) are pending. Cancelled exports leave existing destination files intact."
                alert.addButton(withTitle: "Wait and Quit")
                alert.addButton(withTitle: "Cancel Exports and Quit")
                alert.addButton(withTitle: "Keep RawBrowse Open")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    break
                case .alertSecondButtonReturn:
                    exports.cancelAll()
                default:
                    terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
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
