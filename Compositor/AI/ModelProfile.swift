import Foundation

/// Provider metadata only. Credentials never belong in this value or its JSON representation.
nonisolated struct ModelProfile: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case codexAccount, deepSeek, responses }
    var id: UUID
    var routingID: UUID
    var conversationID: UUID
    var kind: Kind
    var name: String
    var baseURL: String
    var model: String
    var acceptsImages: Bool

    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let deepSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let account = ModelProfile(id: accountID, routingID: accountID, conversationID: accountID, kind: .codexAccount,
                                     name: "ChatGPT / Codex", baseURL: "", model: "", acceptsImages: true)
    static let deepSeek = ModelProfile(id: deepSeekID, routingID: deepSeekID, conversationID: deepSeekID, kind: .deepSeek,
                                      name: "DeepSeek V4.1 Flash", baseURL: "https://api.deepseek.com",
                                      model: "deepseek-flash", acceptsImages: true)
    static func custom() -> ModelProfile {
        let id = UUID()
        return .init(id: id, routingID: id, conversationID: id, kind: .responses, name: "Custom service",
                     baseURL: "https://api.openai.com/v1", model: "", acceptsImages: false)
    }
    var isAPI: Bool { kind != .codexAccount }
    var conversationScope: UUID? { isAPI ? conversationID : nil }
    var supportsImages: Bool {
        kind == .deepSeek ? model == "deepseek-flash" : acceptsImages
    }
    var isLoopback: Bool {
        guard let host = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    func validated() throws -> ModelProfile {
        if !isAPI { return .account }
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CodexRuntimeError(message: "Enter a profile name (up to 80 characters).")
        }
        guard !result.model.isEmpty, result.model.count <= 200,
              !result.model.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw CodexRuntimeError(message: "Enter a model ID without spaces.")
        }
        result.baseURL = try Self.normalizedEndpoint(baseURL)
        if result.kind == .deepSeek && result.baseURL != Self.deepSeek.baseURL { result.kind = .responses }
        return result
    }
    static func normalizedEndpoint(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var url = URLComponents(string: text), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CodexRuntimeError(message: "Enter a base URL without credentials, query parameters, or fragments.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && loopback) else {
            throw CodexRuntimeError(message: "Use HTTPS for remote services. HTTP is allowed only for localhost.")
        }
        url.scheme = url.scheme?.lowercased(); url.host = host
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.hasSuffix("/chat/completions"), !path.hasSuffix("/messages") else {
            throw CodexRuntimeError(message: "This integration requires a Responses API endpoint, not Chat Completions or Messages.")
        }
        if path.hasSuffix("/responses") { path.removeLast("/responses".count) }
        url.path = path
        guard let normalized = url.url?.absoluteString else { throw CodexRuntimeError(message: "Invalid service address.") }
        return normalized
    }
    /// Changing the destination starts a new credential and conversation namespace.
    func replacing(_ previous: ModelProfile?) throws -> ModelProfile {
        var result = try validated()
        if let previous, result.isAPI, previous.baseURL != result.baseURL || previous.kind != result.kind {
            result.routingID = UUID()
            result.conversationID = UUID()
        } else if let previous, result.isAPI, previous.model != result.model || previous.supportsImages != result.supportsImages {
            result.conversationID = UUID()
        }
        return result
    }
}

nonisolated enum ModelProviderConfiguration {
    static let credentialEnvironmentKey = "COMPOSITOR_PROVIDER_API_KEY"
    static let providerID = "compositor_custom"

    static func quote(_ string: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(string), as: UTF8.self)
    }
    static func overrides(_ profile: ModelProfile, catalogURL: URL, usesKey: Bool) throws -> [String] {
        guard profile.isAPI else { return [] }
        let profile = try profile.validated()
        let prefix = "model_providers.\(providerID)"
        var values = [
            "model_provider=\(try quote(providerID))", "model=\(try quote(profile.model))",
            "\(prefix).name=\(try quote(profile.name))", "\(prefix).base_url=\(try quote(profile.baseURL))",
            "\(prefix).wire_api=\"responses\"", "\(prefix).requires_openai_auth=false",
            "\(prefix).supports_websockets=false", "model_catalog_json=\(try quote(catalogURL.path))",
            "model_reasoning_summary=\"none\""
        ]
        if usesKey { values.append("\(prefix).env_key=\(try quote(credentialEnvironmentKey))") }
        if profile.kind == .deepSeek { values.append("model_reasoning_effort=\"high\"") }
        return values.flatMap { ["-c", $0] }
    }
    /// Declare the selected model rather than silently inheriting GPT capability metadata.
    static func catalog(_ profile: ModelProfile, instructions: String) -> CodexJSON {
        let reasoning: [CodexJSON] = profile.kind == .deepSeek ? [
            ["effort": "low", "description": "Low"], ["effort": "high", "description": "High"],
            ["effort": "max", "description": "Maximum"]] : []
        let model: CodexJSON = [
            "slug": .string(profile.model), "display_name": .string(profile.name),
            "description": "User-configured Responses API photo-editing model.",
            "default_reasoning_level": profile.kind == .deepSeek ? "high" : .null,
            "supported_reasoning_levels": .array(reasoning),
            "shell_type": "shell_command", "visibility": "list", "supported_in_api": true,
            "priority": 1, "base_instructions": .string(instructions),
            "supports_reasoning_summaries": false, "support_verbosity": false,
            "default_verbosity": .null, "apply_patch_tool_type": .null,
            "truncation_policy": ["mode": "tokens", "limit": 10000],
            "supports_parallel_tool_calls": false, "context_window": .integer(profile.kind == .deepSeek ? 1048576 : 32768),
            "effective_context_window_percent": 90, "auto_compact_token_limit": .null,
            "input_modalities": profile.supportsImages ? ["text", "image"] : ["text"],
            "supports_image_detail_original": false, "prefer_websockets": false,
            "experimental_supported_tools": [], "supports_search_tool": false,
            "default_reasoning_summary": "none", "model_messages": .null
        ]
        return ["models": [model]]
    }
}
