import AppKit
import Sparkle

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    let updater = AppUpdater()

    func application(_ application: NSApplication, open urls: [URL]) {
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            if let showEditor { showEditor() }
            else { DispatchQueue.main.async { Self.reopen() } }
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }
    private static func reopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit menus and panels follow the same preference as SwiftUI.
        AppTheme.selected.apply()
        SliderSnap.install()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.isDocumentBusy = { [weak self] in
            guard let self else { return true }
            return self.workspace.isManaging || self.workspace.tabs.contains {
                $0.session.isProjectBusy || $0.session.isImporting
            }
        }
        updater.start()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !workspace.isManaging else { updater.terminationWasCancelled(); return .terminateCancel }
        if UpdateActivity.preparingRestart && UpdateActivity.hasActiveChat {
            updater.terminationWasCancelled()
            return .terminateCancel
        }
        Task {
            let confirmed = await workspace.confirmQuit()
            if !confirmed { updater.terminationWasCancelled() }
            sender.reply(toApplicationShouldTerminate: confirmed)
        }
        return .terminateLater
    }
}
