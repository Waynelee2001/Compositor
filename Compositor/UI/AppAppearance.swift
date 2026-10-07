import AppKit
import SwiftUI

nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self { case .light: "Light appearance"; case .dark: "Dark appearance"; case .system: "Follow System" }
    }
    static func preference(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .light
    }
    @MainActor var appearance: NSAppearance? {
        switch self { case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua); case .system: nil }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
    @MainActor func apply() {
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
        }
    }
}

/// Apply to all SwiftUI roots, including separately hosted floating panels and Settings.
struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var rawTheme = AppTheme.light.rawValue
    func body(content: Content) -> some View {
        let theme = AppTheme(rawValue: rawTheme) ?? .light
        content.preferredColorScheme(theme.colorScheme)
            .onAppear { theme.apply() }
            .onChange(of: rawTheme) { _, _ in theme.apply() }
    }
}

struct AppThemePicker: View {
    @AppStorage("appTheme") private var rawTheme = AppTheme.light.rawValue
    var body: some View {
        Picker("Appearance".localizedUI, selection: $rawTheme) {
            ForEach(AppTheme.allCases) { Text($0.title.localizedUI).tag($0.rawValue) }
        }.pickerStyle(.segmented)
        .onChange(of: rawTheme) { _, _ in (AppTheme(rawValue: rawTheme) ?? .light).apply() }
    }
}

struct AppThemeMenu: View {
    @AppStorage("appTheme") private var rawTheme = AppTheme.light.rawValue
    var body: some View {
        Menu {
            Picker("Appearance".localizedUI, selection: $rawTheme) {
                ForEach(AppTheme.allCases) { Text($0.title.localizedUI).tag($0.rawValue) }
            }
        } label: { Image(systemName: "circle.lefthalf.filled") }
        .help("Appearance".localizedUI)
        .onChange(of: rawTheme) { _, _ in (AppTheme(rawValue: rawTheme) ?? .light).apply() }
    }
}

/// Neutral editor chrome, never used by image operations or exported image rendering.
@MainActor
enum EditorPalette {
    static var panel: Color { Color(nsColor: .windowBackgroundColor) }
    static var well: Color { Color(nsColor: .controlBackgroundColor) }
    static var ruler: NSColor { .controlBackgroundColor }
    static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    static func canvas(_ appearance: NSAppearance) -> NSColor { NSColor(white: isDark(appearance) ? 0.105 : 0.90, alpha: 1) }
    static func checker(_ appearance: NSAppearance, alternate: Bool) -> NSColor {
        let value: CGFloat = isDark(appearance) ? (alternate ? 0.35 : 0.30) : (alternate ? 0.89 : 0.97)
        return NSColor(white: value, alpha: 1)
    }
}
