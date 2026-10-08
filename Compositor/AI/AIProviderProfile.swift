import Foundation

/// Metadata only. API credentials live in Keychain, never in this Codable value.
nonisolated struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case codex, deepseek, responses }
    var id: UUID
    var name: String
    var kind: Kind
    var baseURL: String
    var model: String
    var supportsImages: Bool
    var knownModels: [String]
    /// Rotated when connection settings or credentials change; old conversations are not sent to a new endpoint.
    var contextID: UUID
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let codex = AIProviderProfile(id: codexID, name: "Codex / ChatGPT", kind: .codex,
        baseURL: "", model: "", supportsImages: true, knownModels: [], contextID: codexID)
    static func deepSeek() -> Self {
        .init(id: UUID(), name: "DeepSeek V4.1 Flash", kind: .deepseek, baseURL: "https://api.deepseek.com",
              model: "deepseek-flash", supportsImages: true, knownModels: ["deepseek-flash"], contextID: UUID())
    }
    static func custom() -> Self {
        .init(id: UUID(), name: "Custom API", kind: .responses, baseURL: "", model: "",
              supportsImages: false, knownModels: [], contextID: UUID())
    }
    var isCodex: Bool { kind == .codex }
    var scope: String { isCodex ? "" : id.uuidString + "/" + contextID.uuidString }
    var providerID: String { "compositor_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    var acceptsImages: Bool { kind == .deepseek ? model == "deepseek-flash" : supportsImages }

    static func normalizedEndpoint(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AIProviderError("Enter an API base URL without credentials, query parameters, or fragments.")
        }
        let scheme = parts.scheme?.lowercased()
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && local) else {
            throw AIProviderError("Use HTTPS, or HTTP only for localhost/127.0.0.1/::1.")
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/chat/completions") {
            throw AIProviderError("Codex needs a Responses API endpoint, not a Chat Completions endpoint.")
        }
        if parts.path.hasSuffix("/responses") { parts.path.removeLast("/responses".count) }
        guard let url = parts.url else { throw AIProviderError("Invalid API address.") }
        return url
    }
    func validated() throws -> Self {
        guard !isCodex else { return .codex }
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 80, !value.model.isEmpty, value.model.count <= 200,
              !value.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIProviderError("Enter a provider name and a valid model ID.")
        }
        value.baseURL = try Self.normalizedEndpoint(baseURL).absoluteString
        value.knownModels = Array(Set((knownModels + [value.model]).filter { !$0.isEmpty && $0.count <= 200 })).sorted()
        return value
    }
    /// JSON string syntax is also valid for the simple TOML strings used in -c overrides.
    static func quoted(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
    func overrides(catalog: URL) throws -> [String] {
        guard !isCodex else { return [] }
        let profile = try validated(), prefix = "model_providers." + providerID
        let values = [
            "model_provider=" + Self.quoted(providerID), "model=" + Self.quoted(profile.model),
            prefix + ".name=" + Self.quoted(profile.name), prefix + ".base_url=" + Self.quoted(profile.baseURL),
            prefix + ".wire_api=\"responses\"", prefix + ".env_key=\"COMPOSITOR_PROVIDER_API_KEY\"",
            prefix + ".requires_openai_auth=false", prefix + ".supports_websockets=false",
            "model_catalog_json=" + Self.quoted(catalog.path), "model_reasoning_summary=\"none\""
        ]
        return values.flatMap { ["-c", $0] }
    }
    func catalogData() throws -> Data {
        let profile = try validated()
        let ids = Array(Set(profile.knownModels + [profile.model])).sorted()
        let entries: [[String: Any]] = ids.map { id in
            let images = kind == .deepseek ? id == "deepseek-flash" : supportsImages
            return ["slug": id, "display_name": id, "description": profile.name,
                "visibility": "list", "supported_in_api": true, "priority": 1,
                "shell_type": "shell_command", "base_instructions": "Use only the host-provided image editing tools.",
                "default_reasoning_level": "high", "supported_reasoning_levels": [
                    ["effort": "low", "description": "Low"], ["effort": "high", "description": "High"]],
                "supports_reasoning_summaries": false, "default_reasoning_summary": "none",
                "reasoning_summary_format": "experimental", "support_verbosity": false,
                "supports_parallel_tool_calls": true, "input_modalities": images ? ["text", "image"] : ["text"],
                "supports_image_detail_original": false, "prefer_websockets": false,
                "context_window": kind == .deepseek ? 1048576 : 32768,
                "effective_context_window_percent": 90,
                "truncation_policy": ["mode": "tokens", "limit": 10000], "experimental_supported_tools": []]
        }
        return try JSONSerialization.data(withJSONObject: ["models": entries], options: [.sortedKeys])
    }
}

nonisolated struct AIProviderError: LocalizedError {
    let message: String
    var argument: String? = nil
    init(_ message: String, argument: String? = nil) { self.message = message; self.argument = argument }
    var errorDescription: String? {
        let preference = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let locale = preference == "system" ? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en") : preference
        let bundle = Bundle.main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let template = bundle.localizedString(forKey: message, value: message, table: "Providers")
        return argument.map { String(format: template, $0) } ?? template
    }
}

nonisolated enum AIProviderStore {
    static let key = "aiProviderProfiles.v1"
    static let selectionKey = "aiSelectedProvider.v1"
    static func profiles(defaults: UserDefaults = .standard) -> [AIProviderProfile] {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode([AIProviderProfile].self, from: data) else { return [.codex] }
        return [.codex] + stored.filter { !$0.isCodex && $0.id != AIProviderProfile.codexID }
    }
    static func selected(defaults: UserDefaults = .standard) -> AIProviderProfile {
        let id = defaults.string(forKey: selectionKey)
        return profiles(defaults: defaults).first { $0.id.uuidString == id } ?? .codex
    }
    static func save(_ profile: AIProviderProfile, defaults: UserDefaults = .standard) throws {
        let value = try profile.validated()
        var values = profiles(defaults: defaults).filter { !$0.isCodex && $0.id != profile.id }
        if !value.isCodex { values.append(value) }
        try defaults.set(JSONEncoder().encode(values), forKey: key)
    }
    static func delete(_ id: UUID, defaults: UserDefaults = .standard) throws {
        let values = profiles(defaults: defaults).filter { !$0.isCodex && $0.id != id }
        try defaults.set(JSONEncoder().encode(values), forKey: key)
        if defaults.string(forKey: selectionKey) == id.uuidString { defaults.removeObject(forKey: selectionKey) }
    }
}
