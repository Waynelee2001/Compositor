import Foundation
import Security

nonisolated enum AIProviderSecrets {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "compositor") + ".provider-api-key" }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    static func read(_ id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AIProviderError("Could not read the API key from Keychain.") }
        return value
    }
    static func write(_ value: String, for id: UUID) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let request = query(id)
        let update = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AIProviderError("Could not save the API key to Keychain.") }
        var addition = request
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw AIProviderError("Could not save the API key to Keychain.") }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIProviderError("Could not remove the API key from Keychain.") }
    }
}

/// The model discovery request goes only to the explicitly configured origin. Never forward a credential through a redirect.
nonisolated private final class AIProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
nonisolated enum AIProviderHTTP {
    static func models(profile: AIProviderProfile, apiKey: String) async throws -> [String] {
        let base = try AIProviderProfile.normalizedEndpoint(profile.baseURL)
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: AIProviderRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIProviderError("Model list request failed (HTTP %@). Check the address and API key; manual model IDs are also supported.", argument: String(status))
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw AIProviderError("The model list response is too large.") }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (object["data"] ?? object["models"]) as? [[String: Any]] else {
            throw AIProviderError("The endpoint did not return a compatible model list. Enter the model ID manually.")
        }
        let ids = rows.prefix(1000).compactMap { ($0["id"] ?? $0["slug"] ?? $0["model"]) as? String }
            .filter { !$0.isEmpty && $0.count <= 200 }
        guard !ids.isEmpty else { throw AIProviderError("No models were returned. Enter the model ID manually.") }
        return Array(Set(ids)).sorted()
    }
}
