import Foundation

/// One app-owned `codex app-server` child; stdout contains JSONL only.
/// No terminal scraping, HTTP listener, or MCP bridge is involved.
@MainActor
final class CodexRPCConnection {
    /// `never` rejects privilege escalation; native editor edits have their own host approval UI.
    /// Codex 0.160.1 no longer accepts `untrusted` in startup configuration.
    nonisolated static let approvalPolicy = "never"
    var onNotification: ((String, CodexJSON) -> Void)?
    var onRequest: ((CodexJSON, String, CodexJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private var child: CodexChildProcess?
    private var reader: Task<Void, Never>?
    private var parser = CodexJSONLines()
    private let writer = DispatchQueue(label: "compositor.codex.stdin")
    private var sequence = 0
    private var generation = UUID()
    private struct Pending {
        let continuation: CheckedContinuation<CodexJSON, Error>
        let timer: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    var isRunning: Bool { child?.process.isRunning == true }

    func launch(executable: URL, home: URL, workspace: URL, additionalArguments: [String] = [],
                environmentOverrides: [String: String] = [:]) throws {
        disconnect()
        let child = CodexChildProcess()
        self.child = child
        let token = generation
        let process = child.process
        process.executableURL = executable
        process.currentDirectoryURL = workspace
        process.arguments = ["app-server", "--listen", "stdio://",
            "-c", "approval_policy=\"\(Self.approvalPolicy)\"", "-c", "sandbox_mode=\"read-only\"",
            "-c", "web_search=\"disabled\"", "-c", "features.shell_tool=false",
            "-c", "features.unified_exec=false", "-c", "features.apply_patch_freeform=false",
            "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "mcp_servers={}",
            "-c", "cli_auth_credentials_store=\"file\""] + additionalArguments
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR",
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var environment = inherited.filter { allowed.contains($0.key) }
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = [executable.deletingLastPathComponent().path,
                               "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        for (key, value) in environmentOverrides where key == "COMPOSITOR_PROVIDER_API_KEY" { environment[key] = value }
        process.environment = environment
        process.standardInput = child.input
        process.standardOutput = child.output
        process.standardError = child.errors
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        child.output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
        }
        // Drain stderr, but never copy authentication URLs, tokens, or photo data to logs.
        child.errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        reader = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { return }
                guard let self, self.generation == token else { return }
                do { for message in try self.parser.append(data) { self.receive(message) } }
                catch { self.fail(error); return }
            }
            guard let self, self.generation == token else { return }
            do { try self.parser.finish() } catch { self.fail(error); return }
            self.fail(CodexRuntimeError(message: "Codex disconnected. Reconnect to continue."))
        }
        do { try process.run() }
        catch { continuation.finish(); disconnect(); throw error }
    }
    func request(_ method: String, _ params: CodexJSON = [:], timeout: UInt64 = 60) async throws -> CodexJSON {
        guard isRunning else { throw CodexRuntimeError(message: "Codex is not connected.") }
        sequence += 1
        let id = CodexJSON.integer(sequence), key = id.requestKey!
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                    self?.complete(key, .failure(CodexRuntimeError(message: "Codex request timed out: \(method)")))
                }
                pending[key] = Pending(continuation: continuation, timer: timer)
                do { try enqueue(["id": id, "method": .string(method), "params": params]) }
                catch { complete(key, .failure(error)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.complete(key, .failure(CancellationError())) }
        }
    }
    func notify(_ method: String, _ params: CodexJSON = [:]) throws {
        try enqueue(["method": .string(method), "params": params])
    }
    func respond(_ id: CodexJSON, result: CodexJSON) throws { try enqueue(["id": id, "result": result]) }
    func reject(_ id: CodexJSON, message: String) throws {
        try enqueue(["id": id, "error": ["code": -32601, "message": .string(message)]])
    }
    private func enqueue(_ message: CodexJSON) throws {
        guard let handle = child?.input.fileHandleForWriting, isRunning else {
            throw CodexRuntimeError(message: "Codex is not connected.")
        }
        var data = try message.data(); data.append(10)
        let bytes = data, token = generation
        writer.async { [weak self] in
            do { try handle.write(contentsOf: bytes) }
            catch {
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail(error)
                }
            }
        }
    }
    private func receive(_ message: CodexJSON) {
        if let method = message["method"].string {
            if message["id"].requestKey != nil { onRequest?(message["id"], method, message["params"]) }
            else { onNotification?(method, message["params"]) }
            return
        }
        guard let key = message["id"].requestKey else { return }
        if message["error"] != .null {
            complete(key, .failure(CodexRuntimeError(message: message["error"]["message"].string ?? "Codex RPC failed.")))
        } else { complete(key, .success(message["result"])) }
    }
    private func complete(_ key: String, _ result: Result<CodexJSON, Error>) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timer.cancel(); request.continuation.resume(with: result)
    }
    private func fail(_ error: Error) { disconnect(); onDisconnect?(error) }
    func disconnect() {
        generation = UUID()
        reader?.cancel(); reader = nil
        child?.stop(); child = nil
        parser = CodexJSONLines()
        let requests = pending; pending.removeAll()
        for request in requests.values {
            request.timer.cancel()
            request.continuation.resume(throwing: CodexRuntimeError(message: "Codex disconnected."))
        }
    }
}

/// Owns OS resources even if a SwiftUI tab is removed during a turn.
nonisolated private final class CodexChildProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    deinit { stop() }
}
