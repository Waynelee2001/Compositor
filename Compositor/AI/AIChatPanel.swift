import AppKit
import Combine
import SwiftUI
import AIElementsUI
import ShadcnUI

@MainActor
func codexText(_ key: String) -> String {
    AppLanguage.selected.localizedBundle.localizedString(forKey: key, value: key, table: "Codex")
}

/// ShadKit handles streaming Markdown, transcript scrolling and the composer.
/// Host wrappers keep editor permissions and tool status labels localized.
struct AIChatPanel: View {
    @Bindable var session: EditorSession
    @Bindable var chat: AgentChatSession
    var width: CGFloat
    @State private var showsSettings = false
    @State private var confirmsSharing = false
    @State private var apiKey = ""
    @State private var answers: [String: String] = [:]
    private var status: String {
        if chat.isStopping { return codexText("Stopping") }
        if chat.approval != nil { return codexText("Awaiting approval") }
        if chat.isRunning { return codexText("Working") }
        if chat.isConnecting { return codexText("Connecting") }
        return codexText(chat.isConnected ? "Connected" : "Disconnected")
    }
    private var promptStatus: AIPromptStatus {
        if chat.isConnecting { return .submitted }
        return chat.isRunning ? .streaming : .ready
    }
    private var scrollToken: AIConversationToken {
        AIConversationToken(itemCount: chat.transcript.items.count,
                            streamLength: chat.transcript.items.reduce(0) { $0 + $1.text.count + $1.output.count },
                            extra: chat.approval == nil ? 0 : 1)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AIConversation(token: scrollToken, style: .compact) {
                if chat.transcript.items.isEmpty { welcome }
                ForEach(chat.transcript.items) { item in CodexMessageRow(item: item) }
            }
            if let error = chat.errorMessage {
                Text(codexText(error)).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let approval = chat.approval { approvalView(approval) }
            if !chat.questions.isEmpty { questionsView }
            Divider()
            sharingControls
            AIPromptInput(text: $chat.draft, placeholder: codexText("Describe the photo edit…"),
                          status: promptStatus, style: .compact,
                          onSubmit: { Task { await chat.send(using: session) } }, onStop: { chat.stop() },
                          header: { EmptyView() }, tools: {
                              Text(status).font(.caption2).foregroundStyle(.secondary)
                          }, trailing: { EmptyView() })
                .disabled(chat.isConnecting || chat.isStopping || (chat.isExecutingTool && !chat.isRunning))
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: width)
        .shadcnSurface()
        .onAppear { chat.bind(to: session) }
        .onChange(of: session.document?.id) { _, _ in chat.bind(to: session) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in chat.disconnect() }
        .alert(codexText("Share the canvas with the model?"), isPresented: $confirmsSharing) {
            Button(codexText("Cancel"), role: .cancel) { }
            Button(codexText("Allow canvas sharing")) { chat.sharesCanvas = true }
        } message: {
            Text(codexText("Codex may send a 1024px preview of this document to the signed-in model provider. Original image metadata and the .comp package are not attached. Turn this off at any time."))
        }
        .popover(isPresented: $showsSettings) { connectionSettings.frame(width: 380).padding(18) }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Label(codexText("AI Assistant"), systemImage: "sparkles").font(.headline)
            Spacer(minLength: 0)
            Button { chat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .disabled(chat.isRunning || chat.isExecutingTool).help(codexText("New conversation"))
            Button { showsSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help(codexText("AI settings"))
        }.buttonStyle(.plain).padding(14)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(codexText("Edit photos through conversation")).font(.headline)
            Text(codexText("Connect Codex, sign in, and describe the change. Edits run through the editor and can be undone."))
                .font(.callout).foregroundStyle(.secondary)
            Button(codexText("Connect Codex")) { perform { try await chat.connect(); showsSettings = true } }
                .disabled(chat.isConnecting)
            ForEach(["Make the photo clearer without harsh skin texture.", "Give it a warm cinematic look.", "Undo the last edit."], id: \.self) { suggestion in
                Button(codexText(suggestion)) { chat.draft = codexText(suggestion) }
                    .buttonStyle(.bordered).font(.caption)
            }
        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sharingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(codexText("Share canvas preview"), isOn: Binding(get: { chat.sharesCanvas }, set: { value in
                if value { confirmsSharing = true } else { chat.sharesCanvas = false }
            }))
            Toggle(codexText("Confirm each image edit"), isOn: $chat.asksBeforeEdits).disabled(chat.isRunning)
        }.toggleStyle(.checkbox).font(.caption).padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func approvalView(_ approval: CodexEditApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(codexText("Approve this edit?"), systemImage: "hand.raised").font(.headline)
            Text(CodexMessageRow.toolTitle(approval.name)).font(.callout)
            ScrollView { Text(approval.arguments).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 110)
            HStack {
                Button(codexText("Decline")) { chat.resolveApproval(false) }
                Spacer()
                Button(codexText("Apply edit")) { chat.resolveApproval(true) }.buttonStyle(.borderedProminent)
            }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).padding(10)
    }
    private var questionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chat.questions) { question in
                Text(question.text).font(.callout)
                let binding = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                if !question.options.isEmpty {
                    Picker(codexText("Answer"), selection: binding) {
                        Text(codexText("Choose an answer")).tag("")
                        ForEach(question.options, id: \.self) { Text($0).tag($0) }
                    }
                } else if question.isSecret { SecureField(codexText("Answer"), text: binding) }
                else { TextField(codexText("Answer"), text: binding) }
            }
            Button(codexText("Submit answers")) { chat.answerQuestions(answers); answers = [:] }
                .disabled(chat.questions.contains { (answers[$0.id] ?? "").isEmpty })
        }.padding(12)
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(codexText("Codex connection")).font(.headline)
            CodexPreferencesForm()
            Text(status).font(.caption)
            if !chat.serverVersion.isEmpty { Text(chat.serverVersion).font(.caption2).textSelection(.enabled) }
            HStack {
                Button(codexText(chat.isConnected ? "Reconnect" : "Connect")) {
                    chat.disconnect(); perform { try await chat.connect() }
                }.disabled(chat.isRunning || chat.isExecutingTool || chat.isConnecting)
                if chat.isConnected { Button(codexText("Disconnect")) { chat.disconnect() } }
            }
            if chat.isAuthenticated {
                Text(chat.accountLabel).font(.caption).textSelection(.enabled)
                Button(codexText("Sign out")) { perform { try await chat.signOut() } }.disabled(chat.isRunning)
            } else {
                Button(codexText("Sign in with ChatGPT")) { perform { try await chat.signIn() } }.disabled(chat.isConnecting || chat.isRunning)
                Button(codexText("Cancel sign-in")) { Task { await chat.cancelLogin() } }
                DisclosureGroup(codexText("Use an API key")) {
                    SecureField(codexText("API key"), text: $apiKey)
                    Button(codexText("Sign in")) {
                        let key = apiKey; apiKey = ""
                        perform { try await chat.signIn(apiKey: key) }
                    }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isConnecting)
                }
            }
            if !chat.models.isEmpty {
                Picker(codexText("Model"), selection: $chat.modelID) {
                    ForEach(chat.models) { Text($0.title).tag($0.id) }
                }.disabled(chat.isRunning)
            } else { TextField(codexText("Model (automatic when empty)"), text: $chat.modelID).disabled(chat.isRunning) }
            Text(codexText("The model list is a catalog, not a guarantee of account access. Authentication is managed by Codex in a separate local home."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { chat.errorMessage = error.localizedDescription } }
    }
}

private struct CodexMessageRow: View {
    let item: CodexTimelineItem
    static func toolTitle(_ name: String) -> String {
        let titles = ["compositor_get_document_info": "Read document", "compositor_get_canvas_preview": "Inspect canvas",
                      "compositor_apply_camera_raw": "Camera Raw adjustment", "compositor_undo": "Undo", "compositor_redo": "Redo"]
        return codexText(titles[name] ?? name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item.kind {
            case .user:
                Text(codexText("You")).font(.caption2).foregroundStyle(.secondary)
                Text(item.text).textSelection(.enabled).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            case .assistant: AIResponse(item.text).textSelection(.enabled)
            case .summary:
                DisclosureGroup(codexText("Processing summary")) { AIResponse(item.text) }.font(.caption)
            case .notice: Text(codexText(item.text)).font(.caption).foregroundStyle(.secondary)
            case .tool:
                DisclosureGroup {
                    Text(codexText("Parameters")).font(.caption2)
                    AICodeBlock(code: item.arguments, language: "json")
                    if !item.output.isEmpty {
                        Text(codexText("Result")).font(.caption2)
                        Text(codexText(item.output)).font(.caption).textSelection(.enabled)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if item.state == .running { ProgressView().controlSize(.mini) }
                        Text(Self.toolTitle(item.tool)).font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Text(codexText(item.state.rawValue)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodexPreferencesForm: View {
    @AppStorage("codexExecutablePath") private var executablePath = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(codexText("Codex path (automatic when empty)"), text: $executablePath)
                .textFieldStyle(.roundedBorder)
            Button(codexText("Choose Codex executable…")) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.message = codexText("Choose the installed Codex executable.")
                if panel.runModal() == .OK, let url = panel.url { executablePath = url.path }
            }
            Text(codexText("Changes take effect on reconnect. No terminal session is needed while using the editor."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
