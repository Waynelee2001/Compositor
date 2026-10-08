import Foundation
import Observation
import Security

/// Keys are stored separately from editable profile metadata and are never copied to configuration files.
@MainActor
enum ModelCredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "Compositor") + ".provider-api-key" }
    private static func query(_ profile: ModelProfile) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: profile.routingID.uuidString]
    }
    static func read(_ profile: ModelProfile) throws -> String? {
        var request = query(profile)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CodexRuntimeError(message: "Could not read the API key from macOS Keychain.")
        }
        return key
    }
    static func write(_ key: String, for profile: ModelProfile) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CodexRuntimeError(message: "Enter an API key without control characters.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(profile) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(profile); entry.merge(attributes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
                throw CodexRuntimeError(message: "Could not save the API key in macOS Keychain.")
            }
        } else if status != errSecSuccess {
            throw CodexRuntimeError(message: "Could not save the API key in macOS Keychain.")
        }
    }
    static func delete(_ profile: ModelProfile) throws {
        let status = SecItemDelete(query(profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexRuntimeError(message: "Could not remove the API key from macOS Keychain.")
        }
    }
}

@MainActor
@Observable
final class ModelProfileStore {
    static let shared = ModelProfileStore()
    private(set) var profiles: [ModelProfile]
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: "aiModelProfiles")
            .flatMap { $0.count <= 512_000 ? try? JSONDecoder().decode([ModelProfile].self, from: $0) : nil } ?? []
        var seen = Set<UUID>([ModelProfile.accountID])
        profiles = [.account] + stored.compactMap { profile in
            guard profile.isAPI, seen.insert(profile.id).inserted, let valid = try? profile.validated() else { return nil }
            return valid
        }
        if !profiles.contains(where: { $0.id == ModelProfile.deepSeekID }) { profiles.append(.deepSeek) }
    }
    var lastSelected: ModelProfile {
        guard let text = defaults.string(forKey: "aiLastProfile"), let id = UUID(uuidString: text) else { return .account }
        return profile(id) ?? .account
    }
    func profile(_ id: UUID) -> ModelProfile? { profiles.first { $0.id == id } }
    func select(_ profile: ModelProfile) { defaults.set(profile.id.uuidString, forKey: "aiLastProfile") }
    @discardableResult func save(_ value: ModelProfile, newKey: String) throws -> ModelProfile {
        let previous = profile(value.id)
        let updated = try value.replacing(previous)
        if !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try ModelCredentialStore.write(newKey, for: updated)
        } else if updated.isAPI, !updated.isLoopback, try ModelCredentialStore.read(updated) == nil {
            throw CodexRuntimeError(message: "Enter an API key. Changing the service address requires a new key.")
        }
        if let index = profiles.firstIndex(where: { $0.id == updated.id }) { profiles[index] = updated }
        else { profiles.append(updated) }
        defaults.set(try JSONEncoder().encode(profiles), forKey: "aiModelProfiles")
        return updated
    }
    func remove(_ value: ModelProfile) throws {
        guard value.isAPI else { return }
        try ModelCredentialStore.delete(value)
        profiles.removeAll { $0.id == value.id }
        defaults.set(try JSONEncoder().encode(profiles), forKey: "aiModelProfiles")
        if lastSelected.id == value.id { select(.account) }
    }
}
