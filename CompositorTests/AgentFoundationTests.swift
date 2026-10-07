import Testing
@testable import Compositor

@MainActor
struct AgentFoundationTests {
    @Test func stableProtocolNamesAreNotLocalized() {
        #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
        #expect(AdjustmentKind.exposure.rawValue == "Exposure")
        #expect(FilterKind.cameraRaw.rawValue == "Camera Raw Filter")
        #expect(!AdjustmentKind.hsv.displayName.isEmpty)
        #expect(!FilterKind.cameraRaw.displayName.isEmpty)
    }

    @Test func cameraRawArgumentsDetectChanges() throws {
        let empty = CameraRawToolArguments()
        #expect(!empty.hasChanges)

        let data = Data(#"{"dehaze":24,"contrast":8}"#.utf8)
        let decoded = try JSONDecoder().decode(CameraRawToolArguments.self, from: data)
        #expect(decoded.hasChanges)
        #expect(decoded.dehaze == 24)
        #expect(decoded.contrast == 8)
    }

    @Test func registryExposesStructuredCoreTools() {
        let registry = AgentToolRegistry()
        let names = Set(registry.tools.map(\.name))
        #expect(names.contains("get_document_info"))
        #expect(names.contains("apply_camera_raw"))
        #expect(names.contains("undo"))
        #expect(names.contains("redo"))
        #expect(registry.tools.allSatisfy { !$0.inputSchemaJSON.isEmpty })
    }

    @Test func documentContextUsesEditorState() {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480)
        session.addBlankLayer()
        let context = AgentToolRegistry().context(for: session)
        #expect(context.canvasWidth == 640)
        #expect(context.canvasHeight == 480)
        #expect(context.layerCount == 1)
        #expect(context.selectedLayerCount == 1)
    }
}
