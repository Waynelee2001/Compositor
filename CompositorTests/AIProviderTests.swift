import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Compositor

@MainActor
struct AIProviderTests {
    @Test func deepSeekUsesOfficialModelAndImageInput() throws {
        let profile = try AIProviderProfile.deepSeek().validated()
        #expect(profile.model == "deepseek-flash")
        #expect(profile.acceptsImages)
        let catalog = try JSONSerialization.jsonObject(with: profile.catalogData()) as! [String: Any]
        let entry = (catalog["models"] as! [[String: Any]])[0]
        #expect(entry["input_modalities"] as? [String] == ["text", "image"])
        #expect(entry["context_window"] as? Int == 1048576)
    }
    @Test func addressesPreservePortsAndNormalizeResponsesSuffix() throws {
        #expect(try AIProviderProfile.normalizedEndpoint(" http://127.0.0.1:1234/v1/responses/ ").absoluteString == "http://127.0.0.1:1234/v1")
        #expect(try AIProviderProfile.normalizedEndpoint("https://api.deepseek.com/").absoluteString == "https://api.deepseek.com")
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com?api_key=x", "https://example.com/#fragment", "https://example.com/chat/completions"] {
            #expect(throws: AIProviderError.self) { try AIProviderProfile.normalizedEndpoint(value) }
        }
    }
    @Test func providerMetadataNeverContainsCredentials() throws {
        let defaults = UserDefaults(suiteName: "compositor-test-" + UUID().uuidString)!
        defer { defaults.removeObject(forKey: AIProviderStore.key) }
        let profile = AIProviderProfile.deepSeek()
        try AIProviderStore.save(profile, defaults: defaults)
        let json = String(decoding: defaults.data(forKey: AIProviderStore.key)!, as: UTF8.self)
        #expect(!json.contains("apiKey"))
        #expect(AIProviderStore.profiles(defaults: defaults).contains(profile))
        let args = try profile.overrides(catalog: URL(fileURLWithPath: "/tmp/model catalog.json"))
        #expect(args.contains(where: { $0.contains("env_key=") }))
        #expect(args.contains(where: { $0.contains("wire_api=\"responses\"") }))
        #expect(!args.contains(where: { $0.contains("experimental_bearer_token") }))
    }
    @Test func activeTurnPreventsProviderSwitch() throws {
        let chat = AgentChatSession()
        let original = chat.providerProfile
        chat.isRunning = true
        #expect(throws: AIProviderError.self) { try chat.useProvider(.deepSeek()) }
        #expect(chat.providerProfile == original)
        chat.isRunning = false
    }
    @Test func distinctProvidersAndEndpointRevisionsHaveDistinctScopes() {
        let first = AIProviderProfile.deepSeek()
        var second = first
        second.contextID = UUID()
        #expect(first.scope != second.scope)
        #expect(first.scope != AIProviderProfile.deepSeek().scope)
        #expect(AIProviderProfile.codex.scope == "")
    }
    @Test func appearancePaletteIsReadableInBothModes() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(AppTheme.light.colorScheme != AppTheme.dark.colorScheme)
        #expect(AppTheme.system.colorScheme == nil)
        #expect(AppChrome.canvasGray(light) > 0.8)
        #expect(AppChrome.canvasGray(dark) < 0.2)
        #expect(AppChrome.checkerHigh(light) > AppChrome.checkerLow(light))
        #expect(AppChrome.checkerHigh(dark) > AppChrome.checkerLow(dark))
        #expect(!AppChrome.isDark(light))
        #expect(AppChrome.isDark(dark))
    }
}
