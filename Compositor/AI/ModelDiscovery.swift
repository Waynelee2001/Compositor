import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A credentials-only catalog check: no conversation, photo, or inference is sent.
nonisolated enum ModelDiscovery {
    static func request(profile: ModelProfile, key: String) throws -> URLRequest {
        guard !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CodexRuntimeError(message: "Enter an API key without control characters.")
        }
        let endpoint = try ModelProfile.normalizedEndpoint(profile.baseURL)
        guard let url = URL(string: endpoint)?.appendingPathComponent("models") else {
            throw CodexRuntimeError(message: "Invalid service address.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        return request
    }
    static func models(profile: ModelProfile, key: String) async throws -> [String] {
        let request = try request(profile: profile, key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoProviderRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CodexRuntimeError(message: "Invalid model-list response.") }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexRuntimeError(message: "The service rejected the API key or account permissions.")
            }
            if http.statusCode == 404 || http.statusCode == 405 {
                throw CodexRuntimeError(message: "This service has no model-list endpoint. Enter the model ID manually; Responses API support is still required.")
            }
            throw CodexRuntimeError(message: "The model-list request failed (HTTP \(http.statusCode)).")
        }
        return try parse(data)
    }
    static func parse(_ data: Data) throws -> [String] {
        guard data.count <= 2 * 1024 * 1024 else { throw CodexRuntimeError(message: "The model-list response is too large.") }
        let json = try CodexJSON.decode(data)
        guard case .array = json["data"] else { throw CodexRuntimeError(message: "Invalid model-list response.") }
        let models = Set(json["data"].array.compactMap { $0["id"].string }.filter { id in
            !id.isEmpty && id.count <= 200 && !id.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        }).sorted()
        guard !models.isEmpty else { throw CodexRuntimeError(message: "The service returned no models. Enter a model ID manually.") }
        return Array(models.prefix(500))
    }
}

/// Do not forward API keys to a redirection target, even on the same host.
nonisolated private final class NoProviderRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
