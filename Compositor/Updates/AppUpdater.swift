import AppKit
import Combine
import Sparkle
import SwiftUI

/// Weak registration includes AI turns in background project tabs without owning those tabs.
@MainActor enum UpdateActivity {
    private static let chats = NSHashTable<AgentChatSession>.weakObjects()
    static var preparingRestart = false
    static func register(_ chat: AgentChatSession) { chats.add(chat) }
    static var hasActiveChat: Bool {
        chats.allObjects.contains { $0.isRunning || $0.isExecutingTool || $0.isConnecting }
    }
}

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var started = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = "Check for a newer version of Compositor AI."
    @Published private(set) var errorMessage: String?
    @Published private(set) var awaitingRestart = false
    private var controller: SPUStandardUpdaterController!
    private var observations: [AnyCancellable] = []
    private var pendingInstall: (() -> Void)?
    var isDocumentBusy: () -> Bool = { false }
    private var startedOnce = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        observations = [
            updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                Task { @MainActor [weak self] in self?.canCheck = value }
            },
            updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
                Task { @MainActor [weak self] in self?.automaticChecks = value }
            },
            updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] value in
                Task { @MainActor [weak self] in self?.lastChecked = value }
            }
        ]
    }

    func start() {
        guard !startedOnce else { return }
        // Unit-test hosts must never check the network, prompt for updates, or try to replace themselves.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if CODEX_INTEGRATION
        guard UpdatePolicy.isConfigured(Bundle.main.infoDictionary ?? [:]) else {
            errorMessage = "This build does not have a valid signed update channel."
            return
        }
        #endif
        do {
            try controller.updater.start()
            startedOnce = true; started = true
            canCheck = controller.updater.canCheckForUpdates
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            lastChecked = controller.updater.lastUpdateCheckDate
        } catch { errorMessage = error.localizedDescription }
    }

    func check() {
        start()
        guard started, canCheck else { return }
        errorMessage = nil
        status = "Checking for updates…"
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ value: Bool) {
        guard started else { return }
        controller.updater.automaticallyChecksForUpdates = value
        automaticChecks = value
    }

    func resumeInstallation() {
        guard let install = pendingInstall else { return }
        guard !UpdateActivity.hasActiveChat, !isDocumentBusy() else {
            status = "Finish or stop the AI task and any file operations, then click Install and Restart."
            return
        }
        pendingInstall = nil; awaitingRestart = false
        UpdateActivity.preparingRestart = true
        install()
    }

    func terminationWasCancelled() {
        guard UpdateActivity.preparingRestart else { return }
        UpdateActivity.preparingRestart = false
        status = "Restart cancelled. Your current app and documents are unchanged."
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        #if CODEX_INTEGRATION
        guard UpdatePolicy.acceptsArchive(item.fileURL) else {
            throw NSError(domain: "CompositorUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey:
                updateText("The update is not from this app's signed distribution channel.")])
        }
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "A new version is available. Follow the update window to download and install it."
        errorMessage = nil
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Sparkle distinguishes current versions from releases requiring a newer macOS version.
        status = "No compatible newer version is available."
        errorMessage = nil
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        status = "Download complete. The update signature will be verified before installation."
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let value = error as NSError
        if value.domain != SUSparkleErrorDomain || value.code != Int(SUError.noUpdateError.rawValue) {
            errorMessage = error.localizedDescription
            status = "The update did not complete. You can try again; the current app is still installed."
        }
        UpdateActivity.preparingRestart = false
        pendingInstall = nil; awaitingRestart = false
    }
    func userDidCancelDownload(_ updater: SPUUpdater) { status = "Download cancelled. The current app is unchanged." }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunch(installHandler)
    }
    func postponeRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
        if UpdateActivity.hasActiveChat || isDocumentBusy() {
            pendingInstall = installHandler; awaitingRestart = true
            status = "Finish or stop the AI task and any file operations, then click Install and Restart."
            return true
        }
        UpdateActivity.preparingRestart = true
        return false
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

func updateText(_ key: String) -> String {
    AppLanguage.selected.localizedBundle.localizedString(forKey: key, value: key, table: "Updates")
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(updateText("Software Update")).font(.title2).fontWeight(.semibold)
            LabeledContent(updateText("Current version"), value: version)
            Text(updateText("Updates are downloaded and installed inside the app. You choose when to restart."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(updateText("Check for Updates…")) { updater.check() }
                    .disabled(!updater.started || !updater.canCheck || updater.awaitingRestart)
                if updater.awaitingRestart {
                    Button(updateText("Install and Restart")) { updater.resumeInstallation() }
                }
            }
            Text(updateText(updater.status)).font(.callout).textSelection(.enabled)
            if let message = updater.errorMessage {
                Text(updateText(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let date = updater.lastChecked {
                LabeledContent(updateText("Last checked")) { Text(date, format: .dateTime) }.font(.caption)
            }
            Divider()
            Toggle(updateText("Automatically check for updates"), isOn: Binding(
                get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                .disabled(!updater.started)
            Text(updateText("Automatic checks only notify you. Installation and restart require your confirmation. API keys, chats and projects are not sent to the update server."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(20).onAppear { updater.start() }
    }
}
