import AppKit
import SwiftUI

/// App chrome only: these values never participate in a document's pixel pipeline.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    static var selected: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .light
    }
    var title: String {
        switch self {
        case .system: return codexText("Follow System")
        case .light: return codexText("Light appearance")
        case .dark: return codexText("Dark appearance")
        }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    func apply() {
        guard NSApp.appearance?.name != appearance?.name else { return }
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }
}

struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var themeID = AppTheme.light.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeID) ?? .light }
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme.colorScheme)
            .onAppear { theme.apply() }
            .onChange(of: themeID) { _, _ in theme.apply() }
    }
}

struct AppearancePicker: View {
    @AppStorage("appTheme") private var themeID = AppTheme.light.rawValue
    var body: some View {
        Picker(codexText("Appearance"), selection: $themeID) {
            ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
        }.pickerStyle(.menu).onChange(of: themeID) { _, _ in AppTheme.selected.apply() }
    }
}

/// Dynamic neutral colors for the editor surround, rulers, and transparency checker.
/// Keep actual swatches, masks, selection contrast, and exported image colors unchanged.
enum EditorPalette {
    private static func neutral(_ name: String, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name("Compositor." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }
    }
    static let panel = neutral("panel", light: 0.975, dark: 0.14)
    static let canvas = neutral("canvas", light: 0.90, dark: 0.105)
    static let ruler = neutral("ruler", light: 0.955, dark: 0.20)
    static let checkerA = neutral("checkerA", light: 0.90, dark: 0.26)
    static let checkerB = neutral("checkerB", light: 0.97, dark: 0.30)
    static let canvasBorder = neutral("canvasBorder", light: 0.70, dark: 0.35)
    static let graph = neutral("graph", light: 0.94, dark: 0.09)
    static var panelColor: Color { Color(nsColor: panel) }
    static var canvasColor: Color { Color(nsColor: canvas) }
    static var graphColor: Color { Color(nsColor: graph) }
}
