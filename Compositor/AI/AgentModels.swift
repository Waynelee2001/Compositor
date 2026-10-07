import Foundation

struct AgentToolDescriptor: Codable, Equatable, Sendable {
    let name: String
    let description: String
    /// JSON Schema object encoded as UTF-8 JSON. Providers can pass it through to their native tool format.
    let inputSchemaJSON: String
}

struct AgentToolCall: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// Tool arguments encoded as a JSON object.
    let argumentsJSON: String
}

struct AgentToolResult: Codable, Equatable, Sendable {
    let toolCallID: String
    let toolName: String
    let content: String
    let isError: Bool
}

enum AgentMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct AgentMessage: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var role: AgentMessageRole
    var text: String
    var toolCallID: String?
    var toolName: String?

    init(id: UUID = UUID(), role: AgentMessageRole, text: String, toolCallID: String? = nil, toolName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

struct AgentContextSnapshot: Codable, Equatable, Sendable {
    var canvasWidth: Int?
    var canvasHeight: Int?
    var layerCount: Int
    var activeLayerName: String?
    var selectedLayerCount: Int
}

struct AgentProviderRequest: Codable, Equatable, Sendable {
    var messages: [AgentMessage]
    var tools: [AgentToolDescriptor]
    var context: AgentContextSnapshot
}

struct AgentProviderResponse: Codable, Equatable, Sendable {
    var assistantText: String
    var toolCalls: [AgentToolCall]

    init(assistantText: String = "", toolCalls: [AgentToolCall] = []) {
        self.assistantText = assistantText
        self.toolCalls = toolCalls
    }
}
