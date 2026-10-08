import Foundation
import Testing
@testable import Compositor

@MainActor
struct ModelProfileTests {
    @Test func deepSeekPresetUsesVerifiedModelIDAndVision() throws {
        let profile = try ModelProfile.deepSeek.validated()
        #expect(profile.model == "deepseek-flash")
        #expect(profile.baseURL == "https://api.deepseek.com")
        #expect(profile.supportsImages)
        var pro = profile; pro.model = "deepseek-v4-pro"
        #expect(!pro.supportsImages)
    }
    @Test func endpointsAreNormalizedWithoutLosingPathsOrPorts() throws {
        #expect(try ModelProfile.normalizedEndpoint(" https://api.deepseek.com/responses/ ") == "https://api.deepseek.com")
        #expect(try ModelProfile.normalizedEndpoint("http://127.0.0.1:8765/v1/") == "http://127.0.0.1:8765/v1")
        #expect(try ModelProfile.normalizedEndpoint("https://example.com:8443/tenant/v1") == "https://example.com:8443/tenant/v1")
    }
    @Test func invalidDestinationsAndWrongProtocolsAreRejected() {
        for endpoint in ["file:///tmp/model", "http://remote.example/v1", "https://u:p@example.com", "https://example.com?key=secret",
                         "https://example.com/#token", "http://localhost.evil.example:1234", "https://example.com:99999",
                         "https://example.com/v1/chat/completions", "https://example.com/messages", "https://example.com/a\nb"] {
            #expect(throws: (any Error).self) { try ModelProfile.normalizedEndpoint(endpoint) }
        }
    }
    @Test func endpointChangesSeparateKeysAndConversationsWhileModelChangesReuseOnlyKeys() throws {
        let old = ModelProfile.deepSeek
        var changed = old; changed.baseURL = "https://different.example/v1"
        let endpoint = try changed.replacing(old)
        #expect(endpoint.routingID != old.routingID)
        #expect(endpoint.conversationScope != old.conversationScope)
        changed = old; changed.model = "deepseek-v4-pro"
        let model = try changed.replacing(old)
        #expect(model.routingID == old.routingID)
        #expect(model.conversationScope != old.conversationScope)
        changed = old; changed.name = "Renamed"
        let renamed = try changed.replacing(old)
        #expect(renamed.routingID == old.routingID && renamed.conversationScope == old.conversationScope)
    }
    @Test func startupUsesEnvironmentKeyAndResponsesNotEmbeddedCredentials() throws {
        let flags = try ModelProviderConfiguration.overrides(.deepSeek, catalogURL: URL(fileURLWithPath: "/tmp/a b/models.json"), usesKey: true)
        #expect(flags.contains("model_providers.compositor_custom.wire_api=\"responses\""))
        #expect(flags.contains("model_providers.compositor_custom.env_key=\"COMPOSITOR_PROVIDER_API_KEY\""))
        #expect(flags.contains("model_providers.compositor_custom.requires_openai_auth=false"))
        #expect(flags.contains("model=\"deepseek-flash\""))
        #expect(!flags.joined().contains("experimental_bearer_token"))
        #expect(!flags.joined().contains("\\/"))
        #expect(try ModelProviderConfiguration.overrides(.account, catalogURL: URL(fileURLWithPath: "/tmp/models.json"), usesKey: false).isEmpty)
    }
    @Test func customCatalogDoesNotAssumeVisualOrReasoningCapabilities() {
        let catalog = ModelProviderConfiguration.catalog(.deepSeek, instructions: "Only edit photos.")
        #expect(catalog["models"].array[0]["input_modalities"].array == ["text", "image"])
        #expect(catalog["models"].array[0]["supports_reasoning_summaries"].bool == false)
        let custom = ModelProviderConfiguration.catalog(.custom(), instructions: "Only edit photos.")
        #expect(custom["models"].array[0]["input_modalities"].array == ["text"])
        #expect(custom["models"].array[0]["supported_reasoning_levels"].array.isEmpty)
    }
    @Test func discoveryOnlySendsCredentialsToChosenModelListEndpoint() throws {
        let request = try ModelDiscovery.request(profile: .deepSeek, key: "ci-placeholder")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ci-placeholder")
        #expect(throws: (any Error).self) { try ModelDiscovery.request(profile: .deepSeek, key: "bad\r\nkey") }
    }
    @Test func modelListsAreDeduplicatedAndValidateIDs() throws {
        let result = try ModelDiscovery.parse(Data(#"{"data":[{"id":"z"},{"id":"deepseek-flash"},{"id":"z"},{"id":"bad id"}]}"#.utf8))
        #expect(result == ["deepseek-flash", "z"])
        #expect(throws: (any Error).self) { try ModelDiscovery.parse(Data(#"{"choices":[]}"#.utf8)) }
    }
    @Test func metadataAndConversationNamespacesExcludeSecrets() throws {
        let json = String(decoding: try JSONEncoder().encode(ModelProfile.deepSeek), as: UTF8.self)
        #expect(!json.contains("apiKey"))
        #expect(CodexLocalStore.conversationDirectory(nil) == "Conversations")
        #expect(CodexLocalStore.conversationDirectory(ModelProfile.deepSeek.conversationScope) != "Conversations")
    }
    @Test func busyTurnsCannotSwitchProvidersAndIdleSwitchDisablesSharing() {
        let chat = AgentChatSession()
        chat.selectProfile(.account); chat.sharesCanvas = true; chat.isRunning = true
        chat.selectProfile(.deepSeek)
        #expect(chat.profile.kind == .codexAccount)
        chat.isRunning = false; chat.selectProfile(.deepSeek)
        #expect(chat.profile.model == "deepseek-flash" && !chat.sharesCanvas)
        chat.selectProfile(.account)
    }
}
