import AppKit
import Foundation
import Observation

nonisolated struct CodexModelOption: Identifiable, Sendable {
    let id: String
    let title: String
}
nonisolated struct CodexEditApproval: Identifiable {
    let id: String
    let name: String
    let arguments: String
}
nonisolated struct CodexUserQuestion: Identifiable {
    let id: String
    let text: String
    let options: [String]
    let isSecret: Bool
}

@MainActor
@Observable
final class AgentChatSession {
    var draft = ""
    var transcript = CodexTranscript()
    var isRunning = false
    var isConnecting = false
    var isConnected = false
    var isAuthenticated = false
    var isStopping = false
    var isExecutingTool = false
    var errorMessage: String?
    var accountLabel = ""
    var serverVersion = ""
    var models: [CodexModelOption] = []
    var modelID = UserDefaults.standard.string(forKey: "codexModel") ?? "" {
        didSet { UserDefaults.standard.set(modelID, forKey: "codexModel") }
    }
    var sharesCanvas = false
    var asksBeforeEdits = true
    var approval: CodexEditApproval?
    var questions: [CodexUserQuestion] = []
    private(set) var threadID: String?
    private(set) var activeTurnID: String?
    private(set) var documentID: UUID?
    @ObservationIgnored private let rpc = CodexRPCConnection()
    @ObservationIgnored private weak var editor: EditorSession?
    @ObservationIgnored private var workspace: URL?
    @ObservationIgnored private var resumed = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var finishedTurns = Set<String>()
    @ObservationIgnored private var approvalDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var approvalTimer: Task<Void, Never>?
    @ObservationIgnored private var questionRequestID: CodexJSON?
    @ObservationIgnored private var loginID: String?
    @ObservationIgnored private var toolQueue: [(CodexJSON, CodexJSON)] = []
    @ObservationIgnored private var toolTask: Task<Void, Never>?
    @ObservationIgnored private var toolResults: [String: (String, CodexJSON)] = [:]
    @ObservationIgnored private var toolCount = 0
    @ObservationIgnored private var stopTimer: Task<Void, Never>?

    init() {
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params) }
        rpc.onRequest = { [weak self] id, method, params in self?.serverRequest(id, method, params) }
        rpc.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.isConnected = false; self.isAuthenticated = false
            if self.isRunning { self.finish(.interrupted) }
            self.errorMessage = error.localizedDescription
        }
    }
    func bind(to session: EditorSession) {
        editor = session
        guard documentID != session.document?.id else { return }
        disconnect()
        documentID = session.document?.id
        threadID = nil; resumed = false; transcript = CodexTranscript()
        if let id = documentID, let saved = CodexLocalStore.load(id) {
            threadID = saved.threadID; modelID = saved.model; transcript = saved.transcript
            transcript.settle(.interrupted)
        }
    }
    func connect() async throws {
        guard !isConnected else { return }
        guard !isConnecting else { throw CodexRuntimeError(message: "Codex is still connecting.") }
        guard !CodexConfiguration.isAppSandboxed else {
            throw CodexRuntimeError(message: "Use the Codex-enabled build to launch the local agent. The standard build keeps Apple's App Sandbox enabled.")
        }
        let token = epoch
        isConnecting = true; errorMessage = nil
        defer { if epoch == token { isConnecting = false } }
        do {
            let binary = try CodexConfiguration.executable()
            let home = try CodexLocalStore.directory("CodexHome")
            let directory = try CodexLocalStore.directory("Workspace")
            workspace = directory
            try rpc.launch(executable: binary, home: home, workspace: directory)
            let handshake = try await rpc.request("initialize", ["clientInfo": [
                "name": "compositor_photo_editor", "title": "Compositor", "version": "0.2.0"],
                "capabilities": ["experimentalApi": true]])
            guard token == epoch else { throw CancellationError() }
            serverVersion = handshake["userAgent"].string ?? "Codex App Server"
            try rpc.notify("initialized")
            isConnected = true; resumed = false
            try await refreshAccount()
            do { try await refreshModels() }
            catch { if isAuthenticated { errorMessage = error.localizedDescription } }
        } catch {
            if token == epoch { rpc.disconnect(); isConnected = false; errorMessage = error.localizedDescription }
            throw error
        }
    }
    func refreshAccount() async throws {
        let result = try await rpc.request("account/read", ["refreshToken": false])
        isAuthenticated = result["account"] != .null || result["requiresOpenaiAuth"].bool == false
        let account = result["account"]
        accountLabel = account["email"].string ?? account["type"].string ?? ""
    }
    func refreshModels() async throws {
        var choices: [CodexModelOption] = [], cursor = CodexJSON.null
        for _ in 0..<10 {
            let page = try await rpc.request("model/list", ["limit": 100, "cursor": cursor])
            for item in page["data"].array {
                guard let id = item["model"].string ?? item["id"].string else { continue }
                choices.append(.init(id: id, title: item["displayName"].string ?? id))
                if modelID.isEmpty, item["isDefault"].bool == true { modelID = id }
            }
            cursor = page["nextCursor"]
            if cursor == .null { break }
        }
        models = choices
        if modelID.isEmpty { modelID = choices.first?.id ?? "" }
    }
    func signIn() async throws {
        try await connect()
        let result = try await rpc.request("account/login/start", ["type": "chatgpt"])
        guard let address = result["authUrl"].string else { throw CodexRuntimeError(message: "Codex did not return a sign-in address.") }
        let url = try CodexConfiguration.validatedLoginURL(address)
        loginID = result["loginId"].string
        guard NSWorkspace.shared.open(url) else { throw CodexRuntimeError(message: "Could not open the sign-in browser.") }
    }
    func signIn(apiKey: String) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexRuntimeError(message: "Enter an API key.")
        }
        try await connect()
        _ = try await rpc.request("account/login/start", ["type": "apiKey", "apiKey": .string(apiKey)])
        try await refreshAccount(); try await refreshModels()
    }
    func signOut() async throws {
        guard !isRunning, !isExecutingTool else { return }
        _ = try await rpc.request("account/logout")
        isAuthenticated = false; accountLabel = ""
    }
    func cancelLogin() async {
        if let loginID { _ = try? await rpc.request("account/login/cancel", ["loginId": .string(loginID)]) }
        loginID = nil
    }
    func send(using session: EditorSession) async {
        bind(to: session)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !isConnecting, !isExecutingTool else { return }
        let token = epoch
        isRunning = true; isStopping = false; errorMessage = nil
        toolCount = 0; toolResults = [:]; finishedTurns = []
        do {
            try await connect()
            guard token == epoch, !isStopping else { throw CancellationError() }
            guard isAuthenticated else { throw CodexRuntimeError(message: "Sign in to Codex before sending a message.") }
            if !resumed {
                if let threadID {
                    let result = try await rpc.request("thread/resume", ["threadId": .string(threadID),
                        "model": modelID.isEmpty ? .null : .string(modelID),
                        "approvalPolicy": .string(CodexRPCConnection.approvalPolicy), "sandbox": "read-only"])
                    restore(result["thread"]["turns"].array)
                } else {
                    let result = try await rpc.request("thread/start", [
                        "model": modelID.isEmpty ? .null : .string(modelID), "cwd": .string(workspace!.path),
                        "approvalPolicy": .string(CodexRPCConnection.approvalPolicy), "sandbox": "read-only", "ephemeral": false,
                        "baseInstructions": .string(CodexConfiguration.instructions),
                        "dynamicTools": .array(CodexEditorTools.definitions)])
                    guard let id = result["thread"]["id"].string else { throw CodexRuntimeError(message: "Codex did not return a thread ID.") }
                    threadID = id
                }
                resumed = true
            }
            guard token == epoch, !isStopping, let threadID else { throw CancellationError() }
            draft = ""; transcript.addUser(text)
            let result = try await rpc.request("turn/start", ["threadId": .string(threadID),
                "model": modelID.isEmpty ? .null : .string(modelID),
                "input": [["type": "text", "text": .string(text), "text_elements": []]]])
            guard token == epoch else { return }
            guard let turnID = result["turn"]["id"].string else { throw CodexRuntimeError(message: "Codex did not return a turn ID.") }
            if !finishedTurns.contains(turnID) { activeTurnID = turnID }
            if isStopping { stop() }
            persist()
        } catch {
            guard token == epoch else { return }
            errorMessage = error.localizedDescription
            finish(error is CancellationError ? .interrupted : .failed)
            rpc.disconnect(); isConnected = false; isAuthenticated = false; resumed = false
        }
    }
    func stop() {
        guard isRunning else { return }
        isStopping = true; resolveApproval(false); clearQuestions()
        guard let threadID, let turn = activeTurnID else { disconnect(); return }
        let token = epoch
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.rpc.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turn)], timeout: 10) }
            catch { if self.epoch == token { self.disconnect() } }
        }
        stopTimer?.cancel()
        stopTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, self.epoch == token, self.isStopping else { return }
            self.disconnect()
        }
    }
    func disconnect() {
        epoch = UUID(); resolveApproval(false); clearQuestions()
        toolTask?.cancel(); toolTask = nil; toolQueue = []
        if isRunning { finish(.interrupted) }
        rpc.disconnect(); isConnected = false; isConnecting = false; isAuthenticated = false; resumed = false
    }
    func newConversation() {
        guard !isRunning, !isExecutingTool else { return }
        threadID = nil; activeTurnID = nil; resumed = false; transcript = CodexTranscript(); errorMessage = nil
        if let documentID { do { try CodexLocalStore.forget(documentID) } catch { errorMessage = error.localizedDescription } }
    }
    func resolveApproval(_ allow: Bool) {
        approvalTimer?.cancel(); approvalTimer = nil; approval = nil
        let continuation = approvalDecision; approvalDecision = nil; continuation?.resume(returning: allow)
    }
    func answerQuestions(_ values: [String: String]) {
        guard let id = questionRequestID else { return }
        var answers: [String: CodexJSON] = [:]
        for question in questions { answers[question.id] = ["answers": [.string(values[question.id] ?? "")]] }
        try? rpc.respond(id, result: ["answers": .object(answers)])
        questionRequestID = nil; questions = []
    }
    private func clearQuestions() {
        if let id = questionRequestID { try? rpc.respond(id, result: ["answers": [:]]) }
        questionRequestID = nil; questions = []
    }
    private func serverRequest(_ id: CodexJSON, _ method: String, _ params: CodexJSON) {
        guard params["threadId"].string == threadID, isRunning, !isStopping else {
            try? rpc.reject(id, message: "No matching active Compositor turn."); return
        }
        switch method {
        case "item/tool/call":
            guard params["turnId"].string == activeTurnID || activeTurnID == nil else {
                try? rpc.respond(id, result: CodexEditorTools.textResult("Stale tool request.", success: false)); return
            }
            toolQueue.append((id, params))
            if toolTask == nil { toolTask = Task { [weak self] in await self?.drainTools() } }
        case "item/tool/requestUserInput":
            guard questionRequestID == nil else { try? rpc.respond(id, result: ["answers": [:]]); return }
            questionRequestID = id
            questions = params["questions"].array.compactMap { q in
                guard let key = q["id"].string, let text = q["question"].string else { return nil }
                return .init(id: key, text: text, options: q["options"].array.compactMap { $0["label"].string }, isSecret: q["isSecret"].bool ?? false)
            }
            if questions.isEmpty { clearQuestions() }
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            try? rpc.respond(id, result: ["decision": "decline"])
            transcript.notice("Non-editor execution was blocked.")
        default:
            try? rpc.reject(id, message: "This client supports only editor tools and user-input requests.")
        }
    }
    private func drainTools() async {
        let token = epoch
        defer { if epoch == token { toolTask = nil } }
        while !toolQueue.isEmpty, epoch == token, isRunning, !Task.isCancelled {
            let (requestID, params) = toolQueue.removeFirst()
            let name = params["tool"].string ?? "", call = params["callId"].string ?? ""
            let args = params["arguments"], signature = name + args.pretty
            let itemID = (params["turnId"].string ?? "") + "/" + call
            var result: CodexJSON
            do {
                guard !isStopping, !call.isEmpty, params["namespace"] == .null,
                      let editor, let documentID else { throw CodexRuntimeError(message: "No matching document for this tool call.") }
                if let cached = toolResults[call] {
                    guard cached.0 == signature else { throw CodexRuntimeError(message: "Conflicting duplicate tool call.") }
                    try rpc.respond(requestID, result: cached.1); continue
                }
                toolCount += 1
                guard toolCount <= 24 else { throw CodexRuntimeError(message: "Tool-call limit reached. Start a new turn.") }
                try CodexEditorTools.validate(name, arguments: args)
                if CodexEditorTools.mutatingNames.contains(name), asksBeforeEdits {
                    transcript.tool(id: itemID, name: name, arguments: args.pretty, state: .awaitingApproval)
                    let allowed = await withCheckedContinuation { continuation in
                        approvalDecision = continuation
                        approval = .init(id: requestID.requestKey ?? call, name: name, arguments: args.pretty)
                        approvalTimer = Task { [weak self] in
                            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                            self?.resolveApproval(false)
                        }
                    }
                    guard allowed, epoch == token, !isStopping else {
                        transcript.tool(id: itemID, name: name, arguments: args.pretty, state: .denied, output: "Edit declined.")
                        result = CodexEditorTools.textResult("The user declined this edit. Do not retry it without a new request.", success: false)
                        if epoch == token { try? rpc.respond(requestID, result: result); toolResults[call] = (signature, result) }
                        continue
                    }
                }
                transcript.tool(id: itemID, name: name, arguments: args.pretty, state: .running)
                isExecutingTool = true
                defer { isExecutingTool = false }
                result = try await CodexEditorTools.execute(name, arguments: args, session: editor, documentID: documentID, sharesCanvas: sharesCanvas)
                guard epoch == token else { return }
                transcript.tool(id: itemID, name: name, arguments: args.pretty, state: .completed, output: CodexEditorTools.displayOutput(result))
            } catch {
                guard epoch == token else { return }
                result = CodexEditorTools.textResult(error.localizedDescription, success: false)
                transcript.tool(id: itemID, name: name, arguments: args.pretty, state: .failed, output: error.localizedDescription)
            }
            toolResults[call] = (signature, result)
            do { try rpc.respond(requestID, result: result) } catch { errorMessage = error.localizedDescription }
            if toolCount > 24 { stop() }
        }
    }
    private func notification(_ method: String, _ params: CodexJSON) {
        if method == "account/login/completed" {
            loginID = nil
            if params["success"].bool != true { errorMessage = params["error"].string ?? "Sign-in failed." }
            Task { [weak self] in try? await self?.refreshAccount(); try? await self?.refreshModels() }; return
        }
        if method == "account/updated" { Task { [weak self] in try? await self?.refreshAccount() }; return }
        guard params["threadId"].string == threadID else { return }
        if method == "serverRequest/resolved" {
            if params["requestId"].requestKey == approval?.id { resolveApproval(false) }
            if params["requestId"].requestKey == questionRequestID?.requestKey { questionRequestID = nil; questions = [] }
            return
        }
        guard isRunning else { return }
        if method == "turn/started" { activeTurnID = params["turn"]["id"].string }
        if let eventTurn = params["turnId"].string, let activeTurnID, activeTurnID != eventTurn { return }
        if method == "item/started", ["commandExecution", "fileChange", "mcpToolCall"].contains(params["item"]["type"].string ?? "") {
            transcript.notice("Codex attempted a non-editor action. The turn was interrupted."); stop(); return
        }
        transcript.accept(method, params)
        if method == "error", params["willRetry"].bool != true { errorMessage = params["error"]["message"].string ?? "Codex reported an error." }
        if method == "turn/completed" {
            let turn = params["turn"]
            if let id = turn["id"].string { finishedTurns.insert(id) }
            switch turn["status"].string {
            case "completed": finish(.completed)
            case "interrupted": finish(.interrupted)
            default: errorMessage = turn["error"]["message"].string ?? "The Codex turn failed."; finish(.failed)
            }
        }
    }
    private func finish(_ state: CodexTimelineItem.State) {
        isRunning = false; isStopping = false; activeTurnID = nil
        stopTimer?.cancel(); stopTimer = nil
        resolveApproval(false); clearQuestions(); toolQueue = []
        transcript.settle(state); persist()
    }
    private func persist() {
        guard let documentID, let threadID else { return }
        do { try CodexLocalStore.save(.init(documentID: documentID, threadID: threadID, model: modelID, transcript: transcript)) }
        catch { errorMessage = error.localizedDescription }
    }
    private func restore(_ turns: [CodexJSON]) {
        guard !turns.isEmpty else { return }
        var restored = CodexTranscript()
        for turn in turns {
            for item in turn["items"].array {
                if item["type"].string == "userMessage" {
                    let text = item["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
                    if !text.isEmpty { restored.addUser(text) }
                } else { restored.accept("item/completed", ["turnId": turn["id"], "item": item]) }
            }
        }
        restored.settle(.completed); transcript = restored
    }
}
