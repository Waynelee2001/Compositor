import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "Follow System".localizedUI
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }
    private var resolvedLocalization: String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system: return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }
    var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: resolvedLocalization, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
    func applyBundlePreference() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese, .english: UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct AppLanguageSettingsView: View {
    @AppStorage("appLanguage") private var languageRawValue = AppLanguage.system.rawValue
    @State private var showsRestartNotice = false
    private var language: Binding<AppLanguage> {
        Binding(get: { AppLanguage(rawValue: languageRawValue) ?? .system }, set: { newValue in
            languageRawValue = newValue.rawValue
            newValue.applyBundlePreference()
            showsRestartNotice = true
        })
    }
    var body: some View {
        TabView {
            languageForm.tabItem { Label(codexText("General"), systemImage: "globe") }
            VStack(alignment: .leading, spacing: 16) {
                CodexPreferencesForm()
                Text(codexText("Use the AI sidebar settings to connect, sign in, and choose a model."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(20).tabItem { Label("Codex", systemImage: "sparkles") }
        }.padding(12).frame(width: 520, height: 380)
    }
    private var languageForm: some View {
        Form {
            AppThemePicker()
            Picker("Application Language", selection: language) {
                ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
            }.pickerStyle(.menu)
            Text("The editor updates immediately. Restart Compositor to apply the language to all macOS menus and AppKit panels.")
                .font(.caption).foregroundStyle(.secondary)
            if showsRestartNotice {
                Text("Language preference saved. Restart Compositor for the complete change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
}

extension String {
    /// Localizes UI display values without changing stored protocol identifiers.
    var localizedUI: String {
        AppLanguage.selected.localizedBundle.localizedString(forKey: self, value: self, table: nil)
    }
}
