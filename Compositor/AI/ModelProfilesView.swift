import SwiftUI

/// A small profile editor, not a global CLI configuration switcher.
struct ModelProfilesView: View {
    @Bindable var chat: AgentChatSession
    @Bindable private var store = ModelProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ModelProfile.deepSeek
    @State private var apiKey = ""
    @State private var availableModels: [String] = []
    @State private var isChecking = false
    @State private var message: String?
    @State private var isError = false
    @State private var confirmsDeletion = false
    @State private var discovery: Task<Void, Never>?
    @State private var discoveryID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(codexText("Model profiles")).font(.title2.bold())
                Spacer()
                Button(codexText("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker(codexText("Profile"), selection: Binding(get: { draft.id }, set: choose)) {
                    ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    if store.profile(draft.id) == nil { Text(codexText("New custom service")).tag(draft.id) }
                }
                Button(codexText("Add service")) { reset(.custom()) }.disabled(!chat.canChangeProfile)
            }
            if draft.isAPI { apiForm }
            else {
                Text(codexText("ChatGPT / Codex uses the existing browser or OpenAI API-key sign-in. Your usual CLI configuration is unchanged."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message {
                Text(codexText(message)).font(.caption).foregroundStyle(isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Text(codexText("Switching services keeps separate histories and turns canvas sharing off. It does not transfer old chats or photos."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if draft.isAPI, store.profile(draft.id) != nil {
                    Button(codexText("Remove profile"), role: .destructive) { confirmsDeletion = true }
                        .disabled(!chat.canChangeProfile || isChecking)
                }
                Spacer()
                Button(codexText("Save and use")) { save() }
                    .buttonStyle(.borderedProminent).disabled(!chat.canChangeProfile || isChecking)
            }
        }
        .padding(22).frame(width: 580, height: draft.isAPI ? 535 : 320)
        .modifier(AppAppearanceModifier())
        .onAppear { reset(chat.profile) }
        .onDisappear { discovery?.cancel(); apiKey = "" }
        .alert(codexText("Remove this profile and its API key?"), isPresented: $confirmsDeletion) {
            Button(codexText("Cancel"), role: .cancel) { }
            Button(codexText("Remove"), role: .destructive) {
                do {
                    guard chat.canChangeProfile else { return }
                    if chat.profile.id == draft.id { chat.selectProfile(.account) }
                    try store.remove(draft)
                    reset(.account)
                } catch { show(error.localizedDescription, error: true) }
            }
        } message: {
            Text(codexText("Local conversation files are kept. This does not delete anything from the model service."))
        }
    }
    private var apiForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(codexText("Profile name"), text: $draft.name)
            TextField(codexText("Base URL (include a port for local services)"), text: $draft.baseURL)
                .onChange(of: draft.baseURL) { _, _ in invalidateCheck() }
            SecureField(codexText("API key (leave blank to keep the saved key)"), text: $apiKey)
                .onChange(of: apiKey) { _, _ in invalidateCheck() }
            HStack {
                TextField(codexText("Model ID"), text: $draft.model)
                if !availableModels.isEmpty {
                    Menu(codexText("Choose model")) {
                        ForEach(availableModels, id: \.self) { model in Button(model) { draft.model = model } }
                    }
                }
            }
            HStack {
                Button(codexText("Test connection / load models")) { check() }.disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                if draft.id != ModelProfile.deepSeekID {
                    Button(codexText("DeepSeek preset")) { reset(store.profile(ModelProfile.deepSeekID) ?? .deepSeek) }
                }
            }
            if draft.kind == .deepSeek {
                Text(codexText("DeepSeek V4.1 Flash uses deepseek-flash and supports image input."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(codexText("This model supports image input"), isOn: $draft.acceptsImages)
                    .toggleStyle(.checkbox)
            }
            Text(codexText("Requires the Responses API with function calling. Chat Completions-only services are not compatible. Model-list checks do not run inference."))
                .font(.caption).foregroundStyle(.secondary)
            Text(codexText("API keys stay in macOS Keychain. They are not written to the project, CLI config, or chat history."))
                .font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).disabled(!chat.canChangeProfile)
    }
    private func choose(_ id: UUID) { if let profile = store.profile(id) { reset(profile) } }
    private func reset(_ profile: ModelProfile) {
        discovery?.cancel(); discoveryID = UUID(); draft = profile; apiKey = ""
        availableModels = []; isChecking = false; message = nil
    }
    private func invalidateCheck() {
        discovery?.cancel(); discoveryID = UUID(); isChecking = false; availableModels = []; message = nil
    }
    private func show(_ text: String, error: Bool) { message = text; isError = error }
    private func save() {
        guard chat.canChangeProfile else { return }
        do {
            let profile = draft.isAPI ? try store.save(draft, newKey: apiKey) : .account
            apiKey = ""; chat.selectProfile(profile); dismiss()
        } catch { show(error.localizedDescription, error: true) }
    }
    private func check() {
        discovery?.cancel(); let token = UUID(); discoveryID = token
        let candidate = draft, suppliedKey = apiKey
        isChecking = true; message = nil
        discovery = Task { @MainActor in
            defer { if discoveryID == token { isChecking = false } }
            do {
                var candidate = candidate
                candidate.baseURL = try ModelProfile.normalizedEndpoint(candidate.baseURL)
                let previous = store.profile(candidate.id)
                // Never reuse a stored credential at an edited destination.
                let storedKey = previous?.baseURL == candidate.baseURL ? try ModelCredentialStore.read(candidate) : nil
                let key = suppliedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let usedKey = key.isEmpty ? storedKey ?? "" : key
                guard !usedKey.isEmpty || candidate.isLoopback else { throw CodexRuntimeError(message: "Enter an API key.") }
                let choices = try await ModelDiscovery.models(profile: candidate, key: usedKey)
                guard token == discoveryID, !Task.isCancelled else { return }
                availableModels = choices
                if draft.model.isEmpty { draft.model = choices.first ?? "" }
                show("Model list loaded. This verifies the catalog endpoint, not a paid inference request.", error: false)
            } catch {
                guard token == discoveryID, !Task.isCancelled else { return }
                show(error.localizedDescription, error: true)
            }
        }
    }
}
