import Foundation

/// Never follow redirects with a provider credential, use shared cookies, or expose response bodies in errors.
nonisolated private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
enum AIProviderClient {
    static func models(for profile: AIProviderProfile, key: String) async throws -> [String] {
        let result = try await perform(profile, key: key, path: "models")
        let ids = Array(Set(result["data"].array.compactMap { $0["id"].string }.filter(AIProviderProfile.validModel))).sorted()
        guard !ids.isEmpty else { throw CodexRuntimeError(message: "No model IDs were returned. Enter a model ID manually.") }
        return Array(ids.prefix(100))
    }
    /// Explicit user action only. Sends no photograph, document, or conversation history.
    static func test(_ profile: AIProviderProfile, key: String) async throws {
        _ = try profile.validated()
        let body: CodexJSON = ["model": .string(profile.model), "input": "Reply with OK.",
                               "max_output_tokens": 512, "store": false, "stream": false]
        let result = try await perform(profile, key: key, path: "responses", body: body)
        guard result["error"] == .null, !result["output"].array.isEmpty,
              result["status"].string == "completed" else {
            throw CodexRuntimeError(message: "The endpoint responded but did not complete the test. Check model and Responses API compatibility.")
        }
    }
    private static func perform(_ profile: AIProviderProfile, key: String, path: String, body: CodexJSON? = nil) async throws -> CodexJSON {
        let url = try profile.endpoint().appendingPathComponent(path)
        var request = URLRequest(url: url); request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.requiresKey || !token.isEmpty else { throw CodexRuntimeError(message: "Save an API key for this provider in AI settings.") }
        guard !token.contains("\n"), !token.contains("\r") else { throw CodexRuntimeError(message: "Enter a valid API key without line breaks.") }
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"; request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: ProviderRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodexRuntimeError(message: "Invalid API response.") }
            guard (200..<300).contains(http.statusCode) else {
                switch http.statusCode {
                case 401, 403: throw CodexRuntimeError(message: "API authentication failed. Check the key and model permissions.")
                case 404: throw CodexRuntimeError(message: "API route not found. Check the base URL and Responses API support.")
                case 429: throw CodexRuntimeError(message: "API rate limit or account quota reached.")
                case 300..<400: throw CodexRuntimeError(message: "API redirects are blocked to protect your key. Enter the final base URL.")
                default: throw CodexRuntimeError(message: "The provider returned a server error. Try again later.")
                }
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 4 * 1024 * 1024 else { throw CodexRuntimeError(message: "The provider response is too large.") }
            }
            return try CodexJSON.decode(data)
        } catch let error as CodexRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CodexRuntimeError(message: "Could not reach the API. Check the address, port, network, and certificate.") }
    }
}
