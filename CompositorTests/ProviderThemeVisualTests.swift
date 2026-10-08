import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// Runs in its own serial CI step because it temporarily changes the application's appearance.
@MainActor @Suite(.serialized)
struct ProviderThemeVisualTests {
    @Test(.enabled(if: !CodexConfiguration.isAppSandboxed, "The Codex build produces the visual acceptance artifacts."))
    func bothThemesRenderAndDoNotChangeExportedPixels() async throws {
        let defaults = UserDefaults.standard
        let oldTheme = defaults.object(forKey: "appTheme"), oldLanguage = defaults.object(forKey: "appLanguage")
        let oldAppearance = NSApp.appearance
        let previousProfile = ModelProfileStore.shared.lastSelected
        defer {
            defaults.set(oldTheme, forKey: "appTheme"); defaults.set(oldLanguage, forKey: "appLanguage")
            NSApp.appearance = oldAppearance; ModelProfileStore.shared.select(previousProfile)
        }
        defaults.set("zh-Hans", forKey: "appLanguage")
        let session = EditorSession(); session.createDocument(width: 640, height: 480)
        let context = try BrushRaster.context(width: 640, height: 480, mask: false)
        for y in 0..<480 {
            context.setFillColor(CGColor(srgbRed: CGFloat(y) / 480, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 640, height: 1))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "主题测试图"))
        let snapshot = try #require(session.projectSnapshot())
        let baseline = try await ImageExporter.shared.pngData(snapshot)
        let documentID = session.document?.id
        let directory = URL(fileURLWithPath: "/tmp/CompositorThemePreview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in [AppTheme.light, .dark] {
            defaults.set(theme.rawValue, forKey: "appTheme"); theme.apply()
            let chat = AgentChatSession(); chat.bind(to: session); chat.selectProfile(.deepSeek)
            chat.transcript.addUser("让照片更通透，同时保留自然色彩。")
            chat.transcript.accept("item/agentMessage/delta", ["turnId": "preview", "itemId": "text", "delta": "这是聊天界面的显示示例。所有修改都可以撤销。"])
            chat.transcript.tool(id: "preview/tool", name: "compositor_apply_camera_raw", arguments: "{\"dehaze\":12,\"contrast\":4}", state: .completed, output: "Camera Raw adjustment applied.")
            try render(ContentView(session: session), size: CGSize(width: 1320, height: 820),
                       to: directory.appendingPathComponent("editor-\(theme.rawValue).png"))
            try render(ModelProfilesView(chat: chat), size: CGSize(width: 580, height: 535),
                       to: directory.appendingPathComponent("models-\(theme.rawValue).png"))
            chat.disconnect()
            let exported = try await ImageExporter.shared.pngData(try #require(session.projectSnapshot()))
            #expect(exported == baseline)
            #expect(session.document?.id == documentID)
        }
        #expect(AppTheme.system.colorScheme == nil)
    }
    private func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans")))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setContentSize(size); window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        try data.write(to: url, options: .atomic)
    }
}
