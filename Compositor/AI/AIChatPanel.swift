import SwiftUI
import Observation

@MainActor
@Observable
final class AgentChatSession {
    var messages: [AgentMessage] = [
        AgentMessage(role: .assistant, text: String(localized: "Describe the edit you want. AI tools are ready; connect a model provider to enable conversations."))
    ]
    var draft = ""
    var isRunning = false
    var errorMessage: String?

    let registry = AgentToolRegistry()
    var provider: any AgentProvider

    init(provider: any AgentProvider = UnconfiguredAgentProvider()) {
        self.provider = provider
    }

    func send(using session: EditorSession) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        messages.append(AgentMessage(role: .user, text: text))
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let request = AgentProviderRequest(messages: messages, tools: registry.tools, context: registry.context(for: session))
            let response = try await provider.respond(to: request)
            if !response.assistantText.isEmpty {
                messages.append(AgentMessage(role: .assistant, text: response.assistantText))
            }
            for call in response.toolCalls {
                let result = await registry.execute(call, in: session)
                messages.append(AgentMessage(role: .tool, text: result.content, toolCallID: call.id, toolName: call.name))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AIChatPanel: View {
    @Bindable var session: EditorSession
    @Bindable var chat: AgentChatSession
    var width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Assistant", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(18)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: message.role))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let error = chat.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }

            Divider()
            VStack(spacing: 8) {
                TextField("Tell AI how to edit this image…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .onSubmit {
                        Task { await chat.send(using: session) }
                    }
                HStack {
                    Text("\(session.document?.layers.count ?? 0) layers")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await chat.send(using: session) }
                    } label: {
                        if chat.isRunning { ProgressView().controlSize(.small) }
                        else { Label("Send", systemImage: "arrow.up.circle.fill") }
                    }
                    .disabled(chat.isRunning || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
        .frame(width: width)
    }

    private func label(for role: AgentMessageRole) -> String {
        switch role {
        case .system: return String(localized: "System")
        case .user: return String(localized: "You")
        case .assistant: return String(localized: "AI")
        case .tool: return String(localized: "Tool")
        }
    }
}
