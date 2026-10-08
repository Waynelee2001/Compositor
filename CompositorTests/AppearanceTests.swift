import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Compositor

/// Run serially, apart from other window suites; appearance is application-global.
@MainActor
struct AppearanceTests {
    @Test func freshPreferenceIsLightAndSystemIsAvailable() throws {
        let suite = "theme-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppTheme.preference(in: defaults) == .light)
        defaults.set("dark", forKey: "appTheme"); #expect(AppTheme.preference(in: defaults) == .dark)
        defaults.set("system", forKey: "appTheme"); #expect(AppTheme.preference(in: defaults).appearance == nil)
    }
    @Test(.enabled(if: !CodexConfiguration.isAppSandboxed, "Native visual acceptance runs in the Codex configuration."))
    func lightAndDarkChromeKeepExportIdentical() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "appTheme")
        let savedLanguage = defaults.object(forKey: "appLanguage")
        defer {
            defaults.set(saved, forKey: "appTheme"); defaults.set(savedLanguage, forKey: "appLanguage")
            AppTheme.preference().apply()
        }
        defaults.set("zh-Hans", forKey: "appLanguage")
        let session = EditorSession(); session.createDocument(width: 640, height: 480); session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let before = try await ImageExporter.shared.pngData(snapshot)
        let output = URL(fileURLWithPath: "/tmp/compositor-theme-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for theme in [AppTheme.light, .dark] {
            defaults.set(theme.rawValue, forKey: "appTheme"); theme.apply()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = theme.appearance
            let host = NSHostingView(rootView: ContentView(session: session)
                .environment(\.locale, Locale(identifier: "zh-Hans")).frame(width: 1300, height: 780))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 600_000_000)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("Compositor-" + theme.rawValue + ".png"))
            window.orderOut(nil)
            #expect(try await ImageExporter.shared.pngData(snapshot) == before)
        }
    }
}
