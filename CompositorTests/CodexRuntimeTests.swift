import Foundation
import Testing
@testable import Compositor

@MainActor
struct CodexRuntimeTests {
    @Test func jsonLinesHandleSplitUnicodeAndCoalescedFrames() throws {
        let one: CodexJSON = ["id": 7, "result": ["text": "去灰 🌆"]]
        let two: CodexJSON = ["id": "7", "result": true]
        var data = try one.data(); data.append(10); data.append(try two.data()); data.append(contentsOf: [13, 10])
        var parser = CodexJSONLines(), decoded: [CodexJSON] = []
        for byte in data { decoded += try parser.append(Data([byte])) }
        try parser.finish()
        #expect(decoded == [one, two])
        #expect(one["id"].requestKey != two["id"].requestKey)
    }
    @Test func malformedAndTruncatedFramesFailClosed() throws {
        var parser = CodexJSONLines()
        #expect(throws: (any Error).self) { try parser.append(Data("[1,2]\n".utf8)) }
        parser = CodexJSONLines()
        _ = try parser.append(Data("{\"id\":".utf8))
        #expect(throws: (any Error).self) { try parser.finish() }
        parser = CodexJSONLines()
        #expect(throws: (any Error).self) { try parser.append(Data(repeating: 32, count: CodexJSONLines.maximumFrameBytes + 1)) }
    }
    @Test func transcriptReconcilesFinalTextAndRetainsInterruptedOutput() throws {
        var log = CodexTranscript()
        log.accept("item/agentMessage/delta", ["turnId": "t", "itemId": "a", "delta": "Hello"])
        log.accept("item/agentMessage/delta", ["turnId": "t", "itemId": "a", "delta": " world"])
        log.accept("item/completed", ["turnId": "t", "item": ["type": "agentMessage", "id": "a", "text": "Hello world"]])
        #expect(log.items.count == 1)
        #expect(log.items[0].text == "Hello world")
        #expect(log.items[0].state == .completed)
        log.accept("item/agentMessage/delta", ["turnId": "t2", "itemId": "a", "delta": "Partial"])
        log.settle(.interrupted)
        #expect(log.items.last?.text == "Partial")
        #expect(log.items.last?.state == .interrupted)
        let restored = try JSONDecoder().decode(CodexTranscript.self, from: JSONEncoder().encode(log))
        #expect(restored.items == log.items)
    }
    @Test func rawReasoningIsNeverRendered() {
        var log = CodexTranscript()
        log.accept("item/reasoning/textDelta", ["turnId": "t", "itemId": "r", "delta": "private"])
        log.accept("item/completed", ["turnId": "t", "item": ["type": "reasoning", "id": "r", "content": ["private"], "summary": ["Checking the photo"]]])
        #expect(log.items.map(\.text) == ["Checking the photo"])
    }
    @Test func localDenialSurvivesServerCompletion() {
        var log = CodexTranscript()
        log.tool(id: "t/c", name: "compositor_undo", arguments: "{}", state: .denied, output: "Declined")
        log.accept("item/completed", ["turnId": "t", "item": ["type": "dynamicToolCall", "id": "c", "tool": "compositor_undo", "arguments": [:], "success": false]])
        #expect(log.items.count == 1)
        #expect(log.items[0].state == .denied)
    }
    @Test func toolsValidateAndNeverAcceptShellOrUnknownArguments() throws {
        let id = UUID().uuidString
        try CodexEditorTools.validate("compositor_apply_camera_raw", arguments: ["layerId": .string(id), "dehaze": 20])
        for bad: CodexJSON in [["layerId": .string(id)], ["layerId": .string(id), "dehaze": 101], ["layerId": .string(id), "exposure": 6], ["layerId": .string(id), "dehaze": true], ["layerId": .string(id), "command": "delete"]] {
            #expect(throws: (any Error).self) { try CodexEditorTools.validate("compositor_apply_camera_raw", arguments: bad) }
        }
        #expect(throws: (any Error).self) { try CodexEditorTools.validate("shell", arguments: [:]) }
        #expect(throws: (any Error).self) { try CodexEditorTools.validate("compositor_undo", arguments: ["all": true]) }
        #expect(CodexEditorTools.definitions.allSatisfy { $0["type"].string == "function" && $0["inputSchema"]["additionalProperties"].bool == false })
    }
    @Test func previewBytesAreNotPersistedInDisplayOutput() {
        let result: CodexJSON = ["success": true, "contentItems": [["type": "inputImage", "imageUrl": "data:image/jpeg;base64,PRIVATE"]]]
        #expect(!CodexEditorTools.displayOutput(result).contains("PRIVATE"))
    }
    @Test func documentAndPrivacyGuardsRejectStaleTools() async throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        session.addBlankLayer()
        let id = try #require(session.document?.id)
        await #expect(throws: (any Error).self) {
            try await CodexEditorTools.execute("compositor_get_document_info", arguments: [:], session: session, documentID: UUID(), sharesCanvas: false)
        }
        await #expect(throws: (any Error).self) {
            try await CodexEditorTools.execute("compositor_get_canvas_preview", arguments: [:], session: session, documentID: id, sharesCanvas: false)
        }
        let result = try await CodexEditorTools.execute("compositor_get_document_info", arguments: [:], session: session, documentID: id, sharesCanvas: false)
        #expect(result["success"].bool == true)
    }
    @Test func signInURLMustUseApprovedHTTPSHost() throws {
        _ = try CodexConfiguration.validatedLoginURL("https://auth.openai.com/oauth/authorize?state=test")
        for url in ["http://auth.openai.com", "https://auth.openai.com.evil.example", "file:///tmp/login", "https://user@auth.openai.com"] {
            #expect(throws: (any Error).self) { try CodexConfiguration.validatedLoginURL(url) }
        }
    }
    @Test(.enabled(if: !CodexConfiguration.isAppSandboxed, "Subprocess integration runs in the Codex build."))
    func stdioHandshakeServerRequestTimeoutAndDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("mock-codex")
        let source = #"""
        #!/usr/bin/env python3
        import json, sys
        waiting = None
        def emit(value):
            data = (json.dumps(value, ensure_ascii=False) + "\n").encode()
            for byte in data:
                sys.stdout.buffer.write(bytes([byte]))
            sys.stdout.buffer.flush()
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                assert message["params"]["capabilities"]["experimentalApi"]
                emit({"id": message["id"], "result": {"userAgent": "mock"}})
            elif method == "account/read":
                emit({"id": message["id"], "result": {"account": None, "requiresOpenaiAuth": True}})
            elif method == "test/tool":
                waiting = message["id"]
                emit({"id": "host-call", "method": "item/tool/call", "params": {"text": "去灰 🌆"}})
            elif message.get("id") == "host-call":
                assert message["result"]["success"] is True
                emit({"id": waiting, "result": {"acknowledged": True}})
            elif method == "test/eof":
                sys.exit(0)
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let rpc = CodexRPCConnection()
        defer { rpc.disconnect() }
        try rpc.launch(executable: executable, home: directory, workspace: directory)
        let initResult = try await rpc.request("initialize", ["capabilities": ["experimentalApi": true]], timeout: 5)
        #expect(initResult["userAgent"].string == "mock")
        try rpc.notify("initialized")
        let account = try await rpc.request("account/read", timeout: 5)
        #expect(account["account"] == .null)
        rpc.onRequest = { id, method, params in
            #expect(id == "host-call")
            #expect(method == "item/tool/call")
            #expect(params["text"].string == "去灰 🌆")
            try? rpc.respond(id, result: ["success": true])
        }
        let ack = try await rpc.request("test/tool", timeout: 5)
        #expect(ack["acknowledged"].bool == true)
        await #expect(throws: (any Error).self) { try await rpc.request("test/timeout", timeout: 1) }
        await #expect(throws: (any Error).self) { try await rpc.request("test/eof", timeout: 5) }
        #expect(!rpc.isRunning)
    }
}
