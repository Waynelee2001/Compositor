import Foundation

/// Only metadata is Codable. Credentials belong to Keychain, never this value or a transcript.
nonisolated struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case codex, responses }
    var id: String
    var revision = UUID().uuidString
    var name: String
    var kind: Kind
    var baseURL: String
    var model: String
    var models: [String] = []
    var supportsImages = false

    static let codex = Self(id: "codex", revision: "builtin", name: "Codex / ChatGPT", kind: .codex, baseURL: "", model: "")
    static let deepSeek = Self(id: "deepseek", revision: "builtin", name: "DeepSeek V4.1 Flash", kind: .responses,
                              baseURL: "https://api.deepseek.com", model: "deepseek-flash", models: ["deepseek-flash"], supportsImages: true)
    static func custom() -> Self {
        Self(id: UUID().uuidString.lowercased(), name: "Custom provider", kind: .responses,
             baseURL: "https://", model: "")
    }
    /// Bind saved credentials to the exact normalized endpoint, not just an editable profile ID.
    func keychainAccount() throws -> String {
        id + "." + Data(try endpoint().absoluteString.utf8).base64EncodedString()
    }
    var isDeepSeek: Bool { (try? endpoint().host?.lowercased()) == "api.deepseek.com" }
    func acceptsImages(model id: String) -> Bool {
        supportsImages && (!isDeepSeek || ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"].contains(id))
    }
    var requiresKey: Bool { kind == .responses && !((try? endpoint()).map(Self.isLoopback) ?? false) }
    // HTTP is permitted only for a literal loopback host. No credentials in URLs or query strings.
    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
    }
    func endpoint() throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let url = components.url, components.scheme == "https" || (components.scheme == "http" && Self.isLoopback(url)),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CodexRuntimeError(message: "Use an HTTPS base URL, or HTTP on localhost, without credentials or query parameters.")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            throw CodexRuntimeError(message: "This integration needs a Responses API endpoint, not a Chat Completions-only endpoint.")
        }
        if path.hasSuffix("/responses") { path.removeLast("/responses".count) }
        components.path = path
        guard let result = components.url else { throw CodexRuntimeError(message: "Invalid API base URL.") }
        return result
    }
    func validated() throws -> Self {
        guard kind != .codex else { return self }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 160,
              id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
              revision.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else {
            throw CodexRuntimeError(message: "Enter a provider name.")
        }
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseURL = try endpoint().absoluteString
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validModel(copy.model) else { throw CodexRuntimeError(message: "Enter a model ID (up to 128 bytes, without spaces).") }
        copy.models = Array(Set((models + [copy.model]).filter(Self.validModel))).sorted()
        guard copy.models.count <= 100 else { throw CodexRuntimeError(message: "Save at most 100 model IDs per provider.") }
        return copy
    }
    static func validModel(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }
    /// Separate local histories for each endpoint revision and model; never forward another provider's history.
    func conversationScope(model: String) -> String {
        if kind == .codex && model.isEmpty { return "" }
        let encoded = Data((model.isEmpty ? "automatic" : model).utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return "Providers/\(id)/\(revision)/Models/\(encoded)"
    }
    static func tomlString(_ value: String) -> String {
        // JSON basic strings are also valid TOML for these validated string values.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
    func launchOverrides(catalog: URL) throws -> [String] {
        _ = try validated()
        return [
            "model_provider=\(Self.tomlString(id))", "model=\(Self.tomlString(model))",
            "model_providers.\(id).name=\(Self.tomlString(name))",
            "model_providers.\(id).base_url=\(Self.tomlString(try endpoint().absoluteString))",
            "model_providers.\(id).wire_api=\"responses\"",
            "model_providers.\(id).requires_openai_auth=false",
            "model_providers.\(id).supports_websockets=false",
            "model_providers.\(id).env_key=\"COMPOSITOR_PROVIDER_KEY\"",
            "model_catalog_json=\(Self.tomlString(catalog.path))",
            "model_reasoning_summary=\"none\"", "show_raw_agent_reasoning=false"
        ] + (isDeepSeek ? ["model_reasoning_effort=\"high\""] : [])
    }
    /// Codex model metadata, not a claim that every custom model supports vision or reasoning.
    func catalog() -> CodexJSON {
        let ids = Array(Set(models + [model])).filter(Self.validModel).sorted()
        return ["models": .array(ids.enumerated().map { index, id in
            var value: [String: CodexJSON] = [
                "slug": .string(id), "display_name": .string(id == "deepseek-flash" ? "DeepSeek V4.1 Flash" : id),
                "description": .string(name),
                "base_instructions": "You are Compositor's photo-editing assistant. Follow the application's instructions and use only the supplied editor tools.",
                "supported_reasoning_levels": [], "shell_type": "shell_command",
                "visibility": "list", "supported_in_api": true, "priority": .integer(index),
                "availability_nux": .null, "upgrade": .null, "support_verbosity": false, "default_verbosity": .null,
                "apply_patch_tool_type": .null, "truncation_policy": ["mode": "tokens", "limit": 10000],
                "experimental_supported_tools": [], "input_modalities": acceptsImages(model: id) ? ["text", "image"] : ["text"],
                "supports_reasoning_summary_parameter": false, "default_reasoning_summary": "none",
                "include_skills_usage_instructions": false, "include_plugin_usage_instructions": false,
                "include_apps_usage_instructions": false, "use_responses_lite": false,
                "context_window": .integer(isDeepSeek ? 1048576 : 32768), "prefer_websockets": false
            ]
            if isDeepSeek {
                value["default_reasoning_level"] = "high"
                value["supported_reasoning_levels"] = [["effort": "low", "description": "Low"], ["effort": "high", "description": "High"], ["effort": "max", "description": "Maximum"]]
            }
            return .object(value)
        })]
    }
}
