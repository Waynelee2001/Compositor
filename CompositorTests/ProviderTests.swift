import Foundation
import Testing
@testable import Compositor

@MainActor
struct ProviderTests {
    @Test func deepSeekUsesOfficialModelAndResponsesAPI() throws {
        let provider = try AIProviderProfile.deepSeek.validated()
        #expect(provider.model == "deepseek-flash")
        #expect(provider.baseURL == "https://api.deepseek.com")
        #expect(provider.supportsImages)
        #expect(provider.requiresKey)
        let arguments = try provider.launchOverrides(catalog: URL(fileURLWithPath: "/tmp/models.json"))
        #expect(arguments.contains("model_providers.deepseek.wire_api=\"responses\""))
        #expect(arguments.contains("model_providers.deepseek.requires_openai_auth=false"))
        #expect(arguments.contains("model_providers.deepseek.env_key=\"COMPOSITOR_PROVIDER_KEY\""))
        #expect(!arguments.joined().contains("experimental_bearer_token"))
        #expect(provider.catalog()["models"].array.first?["input_modalities"].array == ["text", "image"])
    }
    @Test func endpointsAreNormalizedAndUnsafeAddressesRejected() throws {
        var p = AIProviderProfile.deepSeek
        p.baseURL = "https://example.com:8443/v1/responses/"
        #expect(try p.endpoint().absoluteString == "https://example.com:8443/v1")
        p.baseURL = "http://127.0.0.1:1234/v1"
        #expect(try p.endpoint().port == 1234)
        #expect(!p.requiresKey)
        for address in ["https://user:secret@api.example.com", "https://api.example.com?api_key=secret", "https://api.example.com/#key", "http://example.com", "file:///tmp/api", "http://127.0.0.1.evil.example:1234", "https://api.example.com/chat/completions"] {
            p.baseURL = address
            #expect(throws: (any Error).self) { try p.endpoint() }
        }
    }
    @Test func providerAndModelScopesCannotCrossOrTraverse() {
        let a = AIProviderProfile.deepSeek
        var b = a; b.revision = UUID().uuidString
        #expect(a.conversationScope(model: "a") != b.conversationScope(model: "a"))
        #expect(a.conversationScope(model: "a") != a.conversationScope(model: "b"))
        #expect(!a.conversationScope(model: "../../secret").contains(".."))
        #expect(!AIProviderProfile.validModel("bad\nmodel"))
        #expect(!AIProviderProfile.validModel(String(repeating: "a", count: 129)))
    }
    @Test func metadataContainsNoSecretAndEscapesTOML() throws {
        var p = AIProviderProfile.deepSeek; p.name = "Proxy \"quoted\""
        let text = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!text.contains("apiKey"))
        #expect(AIProviderProfile.tomlString(p.name) == "\"Proxy \\\"quoted\\\"\"")
        #expect(try p.validated().name == p.name)
    }
    @Test func endpointChangesRotateTheConversationScope() throws {
        let suite = "provider-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIProviderStore(defaults: defaults)
        var edited = store.profile("deepseek")
        let original = edited.revision
        edited.baseURL = "https://my-proxy.example/v1"
        try store.save(edited, key: nil)
        #expect(store.profile("deepseek").revision != original)
        #expect(store.profile("codex").kind == .codex)
        let reloaded = AIProviderStore(defaults: defaults)
        #expect(reloaded.profile("deepseek").baseURL == "https://my-proxy.example/v1")
    }
}
