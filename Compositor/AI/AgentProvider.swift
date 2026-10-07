import Foundation

protocol AgentProvider: Sendable {
    func respond(to request: AgentProviderRequest) async throws -> AgentProviderResponse
}

enum AgentProviderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "AI provider is not configured yet.")
        }
    }
}

/// Default placeholder used until a concrete model service is configured.
/// Keeping this separate from the editor prevents model SDKs and API keys from leaking into document logic.
struct UnconfiguredAgentProvider: AgentProvider {
    func respond(to request: AgentProviderRequest) async throws -> AgentProviderResponse {
        throw AgentProviderError.notConfigured
    }
}
