import Foundation
import Observation
import Security

@MainActor
@Observable
final class AIProviderStore {
    static let shared = AIProviderStore()
    private(set) var profiles: [AIProviderProfile]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "aiProviderProfiles").flatMap { try? JSONDecoder().decode([AIProviderProfile].self, from: $0) } ?? []
        profiles = [AIProviderProfile.codex] + saved.filter { $0.kind != .codex && (try? $0.validated()) != nil }
        if !profiles.contains(where: { $0.id == "deepseek" }) { profiles.append(.deepSeek) }
    }
    func profile(_ id: String) -> AIProviderProfile { profiles.first { $0.id == id } ?? .codex }
    var preferredID: String { defaults.string(forKey: "aiPreferredProvider") ?? "codex" }
    func prefer(_ id: String) { defaults.set(id, forKey: "aiPreferredProvider") }
    func save(_ profile: AIProviderProfile, key: String?) throws {
        var value = try profile.validated()
        if let old = profiles.first(where: { $0.id == value.id }),
           old.baseURL != value.baseURL || old.supportsImages != value.supportsImages { value.revision = UUID().uuidString }
        if let key, !key.isEmpty { try AIProviderKeys.set(key, for: value.id) }
        var next = profiles.filter { $0.id != value.id }; next.append(value)
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: "aiProviderProfiles"); profiles = next
    }
    func remove(_ id: String) throws {
        guard id != "codex", id != "deepseek" else { return }
        try AIProviderKeys.remove(id)
        let next = profiles.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(next), forKey: "aiProviderProfiles"); profiles = next
        if preferredID == id { prefer("codex") }
    }
}

/// macOS Keychain. Never store a bearer token in UserDefaults, TOML, command arguments, or transcript JSON.
nonisolated enum AIProviderKeys {
    static var service: String { (Bundle.main.bundleIdentifier ?? "com.compositor") + ".provider-api-keys" }
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func read(_ id: String) throws -> String? {
        var attributes = query(id); attributes[kSecReturnData as String] = true; attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CodexRuntimeError(message: "Could not read the API key from Keychain.")
        }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ raw: String, for id: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8192, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CodexRuntimeError(message: "Enter a valid API key without line breaks.")
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CodexRuntimeError(message: "Could not save the API key in Keychain.") }
        var attributes = query(id); attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw CodexRuntimeError(message: "Could not save the API key in Keychain.")
        }
    }
    static func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexRuntimeError(message: "Could not remove the API key from Keychain.")
        }
    }
}
