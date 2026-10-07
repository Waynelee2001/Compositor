import Foundation

@MainActor
final class AgentToolRegistry {
    let tools: [AgentToolDescriptor]

    init() {
        tools = [
            .init(
                name: "get_document_info",
                description: "Read the current canvas size, layer count, selected layer count, and active layer name.",
                inputSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
            ),
            .init(
                name: "apply_camera_raw",
                description: "Apply a Camera Raw grade to the active raster layer. Only supplied values are changed. Values are clamped by Compositor's existing Camera Raw validation.",
                inputSchemaJSON: #"{"type":"object","properties":{"exposure":{"type":"number"},"contrast":{"type":"number"},"highlights":{"type":"number"},"shadows":{"type":"number"},"whites":{"type":"number"},"blacks":{"type":"number"},"temperature":{"type":"number"},"tint":{"type":"number"},"vibrance":{"type":"number"},"saturation":{"type":"number"},"texture":{"type":"number"},"clarity":{"type":"number"},"dehaze":{"type":"number"}},"additionalProperties":false}"#
            ),
            .init(
                name: "undo",
                description: "Undo the most recent document edit.",
                inputSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
            ),
            .init(
                name: "redo",
                description: "Redo the most recently undone document edit.",
                inputSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
            )
        ]
    }

    func context(for session: EditorSession) -> AgentContextSnapshot {
        AgentContextSnapshot(
            canvasWidth: session.document.map { Int($0.size.width) },
            canvasHeight: session.document.map { Int($0.size.height) },
            layerCount: session.document?.layers.count ?? 0,
            activeLayerName: session.activeLayer?.name,
            selectedLayerCount: session.selectedLayerIDs.count
        )
    }

    func execute(_ call: AgentToolCall, in session: EditorSession) async -> AgentToolResult {
        do {
            switch call.name {
            case "get_document_info":
                let value = context(for: session)
                let data = try JSONEncoder().encode(value)
                return success(call, String(decoding: data, as: UTF8.self))
            case "apply_camera_raw":
                let request = try JSONDecoder().decode(CameraRawToolArguments.self, from: Data(call.argumentsJSON.utf8))
                try await session.applyAgentCameraRaw(request)
                return success(call, String(localized: "Camera Raw adjustment applied."))
            case "undo":
                guard session.canUndo else { throw AgentToolError.unavailable(String(localized: "Nothing to undo.")) }
                session.undo()
                return success(call, String(localized: "Undo complete."))
            case "redo":
                guard session.canRedo else { throw AgentToolError.unavailable(String(localized: "Nothing to redo.")) }
                session.redo()
                return success(call, String(localized: "Redo complete."))
            default:
                throw AgentToolError.unknownTool(call.name)
            }
        } catch {
            return AgentToolResult(toolCallID: call.id, toolName: call.name, content: error.localizedDescription, isError: true)
        }
    }

    private func success(_ call: AgentToolCall, _ content: String) -> AgentToolResult {
        AgentToolResult(toolCallID: call.id, toolName: call.name, content: content, isError: false)
    }
}

enum AgentToolError: LocalizedError {
    case unknownTool(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return String(format: String(localized: "Unknown AI tool: %@"), name)
        case let .unavailable(message):
            return message
        }
    }
}

nonisolated struct CameraRawToolArguments: Codable, Equatable, Sendable {
    var exposure: Double?
    var contrast: Double?
    var highlights: Double?
    var shadows: Double?
    var whites: Double?
    var blacks: Double?
    var temperature: Double?
    var tint: Double?
    var vibrance: Double?
    var saturation: Double?
    var texture: Double?
    var clarity: Double?
    var dehaze: Double?

    var hasChanges: Bool {
        [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
         vibrance, saturation, texture, clarity, dehaze].contains { $0 != nil }
    }
}
