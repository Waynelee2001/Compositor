import Foundation

/// Host-owned editor tools. Codex decides what to request; this adapter validates and executes it.
@MainActor
struct CodexEditorTools {
    static let prefix = "compositor_"
    static let editableParameters = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint", "vibrance", "saturation", "texture", "clarity", "dehaze"]
    static let mutatingNames: Set<String> = ["compositor_apply_camera_raw", "compositor_undo", "compositor_redo"]
    static var definitions: [CodexJSON] {
        func tool(_ name: String, _ description: String, _ schema: CodexJSON = ["type": "object", "properties": [:], "additionalProperties": false]) -> CodexJSON {
            ["type": "function", "name": .string(prefix + name), "description": .string(description),
             "inputSchema": schema, "deferLoading": false]
        }
        var properties: [String: CodexJSON] = ["layerId": ["type": "string", "description": "The activeLayerId returned by get_document_info."]]
        for key in editableParameters {
            let limit = key == "exposure" ? 5 : 100
            properties[key] = ["type": "number", "minimum": .integer(-limit), "maximum": .integer(limit)]
        }
        return [
            tool("get_document_info", "Read document ID, active layer ID, dimensions, and layer structure before making edits."),
            tool("get_canvas_preview", "See a 1024px composite JPEG of the current canvas, only when the user enabled canvas sharing. No full project files or original image metadata are sent."),
            tool("apply_camera_raw", "Apply conservative Camera Raw adjustments to the named active raster layer. Each call processes current pixels, commits one undoable edit, and does not set a persistent absolute grade.",
                 ["type": "object", "properties": .object(properties), "required": ["layerId"], "minProperties": 2, "additionalProperties": false]),
            tool("undo", "Undo the latest edit in the bound document. This can also undo a manual edit; use only when the user asks."),
            tool("redo", "Redo the latest undone edit in the bound document, when the user asks.")
        ]
    }
    static func validate(_ name: String, arguments: CodexJSON) throws {
        let supported = Set(definitions.compactMap { $0["name"].string })
        guard supported.contains(name), case .object(let values) = arguments else {
            throw CodexRuntimeError(message: "Unsupported editor tool or arguments.")
        }
        if name == "compositor_apply_camera_raw" {
            guard let layer = values["layerId"]?.string, UUID(uuidString: layer) != nil,
                  values.count > 1, values.keys.allSatisfy({ $0 == "layerId" || editableParameters.contains($0) }) else {
                throw CodexRuntimeError(message: "Camera Raw requires a layer ID and supported numeric parameters.")
            }
            for (key, value) in values where key != "layerId" {
                let limit: Double = key == "exposure" ? 5 : 100
                guard let number = value.double, number.isFinite, (-limit...limit).contains(number) else {
                    throw CodexRuntimeError(message: "Camera Raw parameter is out of range: \(key)")
                }
            }
        } else if !values.isEmpty { throw CodexRuntimeError(message: "This editor tool does not accept arguments.") }
    }
    static func execute(_ name: String, arguments: CodexJSON, session: EditorSession,
                        documentID: UUID, sharesCanvas: Bool) async throws -> CodexJSON {
        try validate(name, arguments: arguments)
        try Task.checkCancellation()
        guard let document = session.document, document.id == documentID else {
            throw CodexRuntimeError(message: "The document changed. Start a new turn for the current document.")
        }
        if name == "compositor_get_document_info" {
            let layers: [CodexJSON] = document.layers.map { layer in
                ["id": .string(layer.id.uuidString), "name": .string(layer.name), "visible": .bool(layer.isVisible),
                 "opacity": .number(Double(layer.opacity)), "isGroup": .bool(layer.isGroup),
                 "isRaster": .bool(layer.asset != nil && layer.adjustment == nil && !layer.isGroup)]
            }
            let info: CodexJSON = ["documentId": .string(document.id.uuidString), "width": .integer(document.width),
                                  "height": .integer(document.height), "layers": .array(layers),
                                  "activeLayerId": session.activeLayerID.map { .string($0.uuidString) } ?? .null,
                                  "canvasSharing": .bool(sharesCanvas)]
            return textResult(info.pretty)
        }
        guard !session.isProjectBusy, session.filterEdit == nil, session.levels == nil, session.hueSaturation == nil else {
            throw CodexRuntimeError(message: "Finish the current editor operation before running an AI tool.")
        }
        if name == "compositor_get_canvas_preview" {
            guard sharesCanvas else { throw CodexRuntimeError(message: "Canvas sharing is off. Ask the user to enable it.") }
            guard let snapshot = session.projectSnapshot(), document.width * document.height <= 50_000_000 else {
                throw CodexRuntimeError(message: "This canvas is too large for an AI preview. Use a smaller canvas.")
            }
            session.isProjectBusy = true
            defer { session.isProjectBusy = false }
            let preview = await ImageExporter.shared.quickLookImages(snapshot)
            try Task.checkCancellation()
            guard session.document?.id == documentID, let data = preview?.preview, data.count <= 3 * 1024 * 1024 else {
                throw CodexRuntimeError(message: "Could not create a canvas preview.")
            }
            return ["success": true, "contentItems": [
                ["type": "inputText", "text": "Current canvas composite; white background behind transparency; at most 1024 pixels on the long side."],
                ["type": "inputImage", "imageUrl": .string("data:image/jpeg;base64," + data.base64EncodedString())]
            ]]
        }
        guard session.canEditLayers else { throw CodexRuntimeError(message: "The editor is not ready for an AI edit.") }
        if name == "compositor_apply_camera_raw" {
            guard arguments["layerId"].string == session.activeLayerID?.uuidString else {
                throw CodexRuntimeError(message: "The active layer changed. Read document info again before editing.")
            }
            var values = arguments.object; values.removeValue(forKey: "layerId")
            let request = try JSONDecoder().decode(CameraRawToolArguments.self, from: CodexJSON.object(values).data())
            try await session.applyAgentCameraRaw(request)
            // commitFilter handles errors internally; do not report success on an uncommitted dialog.
            guard session.filterEdit == nil else {
                throw CodexRuntimeError(message: "Camera Raw did not commit. Check or cancel the editor's filter dialog.")
            }
            return textResult("Camera Raw adjustment applied. The edit can be undone in Compositor.")
        }
        if name == "compositor_undo" {
            guard session.canUndo else { throw CodexRuntimeError(message: "Nothing to undo.") }
            session.undo(); return textResult("Undo complete.")
        }
        guard session.canRedo else { throw CodexRuntimeError(message: "Nothing to redo.") }
        session.redo(); return textResult("Redo complete.")
    }
    static func textResult(_ text: String, success: Bool = true) -> CodexJSON {
        ["success": .bool(success), "contentItems": [["type": "inputText", "text": .string(text)]]]
    }
    static func displayOutput(_ result: CodexJSON) -> String {
        result["contentItems"].array.compactMap { item in
            item["type"].string == "inputImage" ? "Canvas preview sent (1024px maximum)." : item["text"].string
        }.joined(separator: "\n")
    }
}
