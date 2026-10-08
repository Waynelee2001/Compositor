import Foundation

nonisolated struct CodexTimelineItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case user, assistant, summary, tool, notice }
    enum State: String, Codable, Sendable { case running, awaitingApproval, completed, failed, denied, interrupted }
    var id: String
    var kind: Kind
    var text = ""
    var tool = ""
    var arguments = ""
    var output = ""
    var state: State = .running
}

/// The transcript is a projection of Codex events, not a second agent loop.
nonisolated struct CodexTranscript: Codable, Sendable {
    var items: [CodexTimelineItem] = []
    var revision = 0
    mutating func addUser(_ text: String) {
        items.append(.init(id: UUID().uuidString, kind: .user, text: text, state: .completed)); revision += 1
    }
    mutating func notice(_ text: String) {
        items.append(.init(id: UUID().uuidString, kind: .notice, text: text, state: .completed)); revision += 1
    }
    mutating func tool(id: String, name: String, arguments: String, state: CodexTimelineItem.State, output: String = "") {
        let index = ensure(id, kind: .tool)
        items[index].tool = name; items[index].arguments = arguments
        items[index].state = state
        if !output.isEmpty { items[index].output = output }
        revision += 1
    }
    mutating func settle(_ state: CodexTimelineItem.State) {
        for i in items.indices where items[i].state == .running || items[i].state == .awaitingApproval {
            items[i].state = state
        }
        revision += 1
    }
    mutating func accept(_ method: String, _ params: CodexJSON) {
        let item = params["item"], turn = params["turnId"].string ?? ""
        let itemID = params["itemId"].string ?? item["id"].string ?? ""
        guard !itemID.isEmpty else { return }
        let id = turn + "/" + itemID
        switch method {
        case "item/agentMessage/delta":
            let i = ensure(id, kind: .assistant); items[i].text += params["delta"].string ?? ""
        case "item/reasoning/summaryTextDelta":
            let i = ensure(id, kind: .summary); items[i].text += params["delta"].string ?? ""
        case "item/reasoning/summaryPartAdded":
            let i = ensure(id, kind: .summary)
            if !items[i].text.isEmpty { items[i].text += "\n\n" }
        case "item/started", "item/completed":
            let complete = method == "item/completed"
            switch item["type"].string {
            case "agentMessage":
                let i = ensure(id, kind: .assistant)
                if let text = item["text"].string, !text.isEmpty { items[i].text = text }
                if complete { items[i].state = .completed }
            case "reasoning":
                // Only the public summary is rendered. Never read `content` or raw reasoning deltas.
                let summary = item["summary"].array.compactMap { $0.string ?? $0["text"].string }.joined(separator: "\n\n")
                if !summary.isEmpty { let i = ensure(id, kind: .summary); items[i].text = summary }
                if complete, let i = items.firstIndex(where: { $0.id == id }) { items[i].state = .completed }
            case "dynamicToolCall":
                let i = ensure(id, kind: .tool)
                items[i].tool = item["tool"].string ?? items[i].tool
                items[i].arguments = item["arguments"].pretty
                if complete {
                    if items[i].state != .denied && items[i].state != .interrupted {
                        items[i].state = item["success"].bool == false || item["status"].string == "failed" ? .failed : .completed
                    }
                    let output = item["contentItems"].array.compactMap { $0["text"].string }.joined(separator: "\n")
                    if !output.isEmpty { items[i].output = output }
                }
            default: return
            }
        default: return
        }
        revision += 1
    }
    private mutating func ensure(_ id: String, kind: CodexTimelineItem.Kind) -> Int {
        if let i = items.firstIndex(where: { $0.id == id }) { return i }
        items.append(.init(id: id, kind: kind)); return items.count - 1
    }
}

nonisolated struct CodexSavedConversation: Codable {
    static let currentVersion = 1
    var version = currentVersion
    let documentID: UUID
    let threadID: String
    let model: String
    var transcript: CodexTranscript
}

nonisolated enum CodexLocalStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compositor/AI", isDirectory: true)
    }
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
    static func conversationDirectory(_ scope: UUID?) -> String {
        scope.map { "Conversations/" + $0.uuidString } ?? "Conversations"
    }
    static func load(_ documentID: UUID, scope: UUID? = nil) -> CodexSavedConversation? {
        guard let url = try? directory(conversationDirectory(scope)).appendingPathComponent(documentID.uuidString + ".json"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024,
              let saved = try? JSONDecoder().decode(CodexSavedConversation.self, from: data),
              saved.version == CodexSavedConversation.currentVersion, saved.documentID == documentID else { return nil }
        return saved
    }
    static func save(_ conversation: CodexSavedConversation, scope: UUID? = nil) throws {
        let url = try directory(conversationDirectory(scope)).appendingPathComponent(conversation.documentID.uuidString + ".json")
        let data = try JSONEncoder().encode(conversation)
        guard data.count <= 4 * 1024 * 1024 else { throw CodexRuntimeError(message: "Conversation is too large to save locally.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func forget(_ documentID: UUID, scope: UUID? = nil) throws {
        let url = try directory(conversationDirectory(scope)).appendingPathComponent(documentID.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
