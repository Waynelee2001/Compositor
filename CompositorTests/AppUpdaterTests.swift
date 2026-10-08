import AppKit
import Testing
@testable import Compositor

@MainActor struct AppUpdaterTests {
    @Test func onlyOurHTTPSReleaseAssetsAreAccepted() {
        let good = "https://github.com/Waynelee2001/Compositor/releases/download/ai-v1.5.0/Compositor-AI-arm64.zip"
        #expect(UpdatePolicy.acceptsArchive(URL(string: good)))
        for bad in [good.replacingOccurrences(of: "https:", with: "http:"),
                    good.replacingOccurrences(of: "Waynelee2001", with: "robbietilton"),
                    good.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
                    good + "?key=secret", good + "#fragment",
                    good.replacingOccurrences(of: "ai-v", with: "v"),
                    good.replacingOccurrences(of: "github.com/", with: "github.com:443/"),
                    good.replacingOccurrences(of: "arm64.zip", with: "intel.zip")] {
            #expect(!UpdatePolicy.acceptsArchive(URL(string: bad)))
        }
        #expect(!UpdatePolicy.acceptsArchive(nil))
    }
    @Test func missingOrChangedTrustSettingsDisableTheChannel() {
        var info: [String: Any] = ["CFBundleIdentifier": UpdatePolicy.bundleID,
            "SUFeedURL": UpdatePolicy.feed, "SUPublicEDKey": UpdatePolicy.publicKey,
            "SUVerifyUpdateBeforeExtraction": true, "SUAllowsAutomaticUpdates": false]
        #expect(UpdatePolicy.isConfigured(info))
        info["SUPublicEDKey"] = ""
        #expect(!UpdatePolicy.isConfigured(info))
        info["SUPublicEDKey"] = UpdatePolicy.publicKey
        info["SUFeedURL"] = "https://example.com/feed.xml"
        #expect(!UpdatePolicy.isConfigured(info))
    }
    @Test func chatInAnyTabPreventsRestart() {
        let first = AgentChatSession(), second = AgentChatSession()
        first.isRunning = true
        #expect(UpdateActivity.hasActiveChat)
        first.isRunning = false; second.isExecutingTool = true
        #expect(UpdateActivity.hasActiveChat)
        second.isExecutingTool = false
    }
    @Test func testHostDoesNotStartUpdaterOrSendNetworkRequests() {
        let updater = AppUpdater()
        updater.start()
        #expect(!updater.started)
        #expect(!updater.awaitingRestart)
    }
    @Test func busyRestartWaitsForAnotherExplicitInstallClick() {
        let updater = AppUpdater()
        var busy = true, installed = false
        updater.isDocumentBusy = { busy }
        defer { UpdateActivity.preparingRestart = false }
        #expect(updater.postponeRelaunch { installed = true })
        #expect(updater.awaitingRestart)
        updater.resumeInstallation()
        #expect(!installed)
        busy = false
        #expect(!installed)
        updater.resumeInstallation()
        #expect(installed)
        #expect(UpdateActivity.preparingRestart)
        updater.terminationWasCancelled()
        #expect(!UpdateActivity.preparingRestart)
    }
    @Test func restartingDoesNotConsumeOrSendDrafts() async {
        UpdateActivity.preparingRestart = true
        defer { UpdateActivity.preparingRestart = false }
        let chat = AgentChatSession()
        chat.draft = "Keep this unsent text"
        await chat.send(using: EditorSession())
        #expect(chat.draft == "Keep this unsent text")
        #expect(!chat.isRunning)
        #expect(chat.errorMessage != nil)
    }
}
