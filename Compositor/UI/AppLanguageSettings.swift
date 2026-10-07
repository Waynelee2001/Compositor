import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "Follow System")
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

    func applyBundlePreference() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese, .english:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct AppLanguageSettingsView: View {
    @AppStorage("appLanguage") private var languageRawValue = AppLanguage.system.rawValue
    @State private var showsRestartNotice = false

    private var language: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRawValue) ?? .system },
            set: { newValue in
                languageRawValue = newValue.rawValue
                newValue.applyBundlePreference()
                showsRestartNotice = true
            }
        )
    }

    var body: some View {
        Form {
            Picker("Application Language", selection: language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)

            Text("The editor updates immediately. Restart Compositor to apply the language to all macOS menus and AppKit panels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsRestartNotice {
                Text("Language preference saved. Restart Compositor for the complete change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

extension String {
    /// Localizes a stable English UI/protocol display value without changing the stored raw value.
    var localizedUI: String {
        NSLocalizedString(self, comment: "")
    }
}
