import Foundation
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    @Test func applicationLanguagesKeepStableIdentifiers() {
        #expect(AppLanguage.system.rawValue == "system")
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.simplifiedChinese.locale.identifier.hasPrefix("zh"))
        #expect(AppLanguage.english.locale.identifier.hasPrefix("en"))
    }

    @Test func persistedProtocolValuesRemainEnglish() {
        #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
        #expect(AdjustmentKind.exposure.rawValue == "Exposure")
        #expect(FilterKind.cameraRaw.rawValue == "Camera Raw Filter")
        #expect(ShapeKind.rectangle.rawValue == "Rectangle")
        #expect(LayerBlendMode.multiply.rawValue == "Multiply")
    }

    @Test func chineseLocalizationCatalogIsRegistered() throws {
        let bundle = AppLanguage.simplifiedChinese.localizedBundle
        let translated = bundle.localizedString(forKey: "Layers", value: nil, table: nil)
        #expect(translated == "图层")
        #expect("Layers".localizedUI.isEmpty == false)
    }
}
