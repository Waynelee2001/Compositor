import Foundation

extension EditorSession {
    /// Applies a structured Camera Raw request through the same filter commit path as the UI,
    /// so AI edits participate in normal document history and can be undone/redone.
    func applyAgentCameraRaw(_ arguments: CameraRawToolArguments) async throws {
        guard arguments.hasChanges else { throw AgentToolError.unavailable(String(localized: "No Camera Raw changes were supplied.")) }
        guard canAdjustColors, activeLayer?.asset != nil, !isMaskSelected else {
            throw AgentToolError.unavailable(String(localized: "Camera Raw is not available for the current layer."))
        }

        beginFilter(.cameraRaw)
        guard let edit = filterEdit, edit.kind == .cameraRaw else {
            throw AgentToolError.unavailable(String(localized: "Could not start Camera Raw for the current layer."))
        }

        var settings = edit.settings
        var raw = settings.cameraRaw
        if let value = arguments.exposure { raw.exposure = value }
        if let value = arguments.contrast { raw.contrast = value }
        if let value = arguments.highlights { raw.highlights = value }
        if let value = arguments.shadows { raw.shadows = value }
        if let value = arguments.whites { raw.whites = value }
        if let value = arguments.blacks { raw.blacks = value }
        if let value = arguments.temperature { raw.temperature = value }
        if let value = arguments.tint { raw.tint = value }
        if let value = arguments.vibrance { raw.vibrance = value }
        if let value = arguments.saturation { raw.saturation = value }
        if let value = arguments.texture { raw.texture = value }
        if let value = arguments.clarity { raw.clarity = value }
        if let value = arguments.dehaze { raw.dehaze = value }
        settings.cameraRaw = raw.normalized

        updateFilter(settings, preview: false)
        await commitFilter()
    }
}
