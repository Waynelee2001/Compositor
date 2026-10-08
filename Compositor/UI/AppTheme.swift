import AppKit
import SwiftUI

/// Appearance is UI state, never part of a .comp document or exported raster.
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    static let preferenceKey = "appTheme"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .light }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
    var appearance: NSAppearance? {
        switch self { case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua); case .system: nil }
    }
    var title: String {
        let key: String
        switch self { case .light: key = "Light"; case .dark: key = "Dark"; case .system: key = "Follow System" }
        return providerText(key)
    }
    func apply() {
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            if let view = window.contentView { invalidate(view) }
        }
    }
    private func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        for child in view.subviews { invalidate(child) }
    }
}

struct AppThemePicker: View {
    @AppStorage(AppTheme.preferenceKey) private var value = AppTheme.light.rawValue
    var body: some View {
        Picker(providerText("Appearance"), selection: $value) {
            ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
        }
        .onChange(of: value) { _, _ in AppTheme.selected.apply() }
    }
}

/// Shared chrome colors keep SwiftUI, AppKit, and the GPU viewport in agreement.
nonisolated enum AppChrome {
    static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    static func canvasGray(_ appearance: NSAppearance) -> CGFloat { isDark(appearance) ? 0.105 : 0.89 }
    static func checkerLow(_ appearance: NSAppearance) -> CGFloat { isDark(appearance) ? 0.30 : 0.92 }
    static func checkerHigh(_ appearance: NSAppearance) -> CGFloat { isDark(appearance) ? 0.35 : 0.99 }
    static func gray(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(white: isDark(appearance) ? dark : light, alpha: 1) }
    }
    static var panel: NSColor { gray(light: 0.975, dark: 0.14) }
    static var ruler: NSColor { gray(light: 0.94, dark: 0.20) }
    static var plot: NSColor { gray(light: 0.95, dark: 0.09) }
    static var canvas: NSColor { gray(light: 0.89, dark: 0.105) }
    static var stroke: NSColor { .separatorColor }
}
