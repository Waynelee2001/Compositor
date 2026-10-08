import SwiftUI

@MainActor
func providerText(_ key: String) -> String {
    AppLanguage.selected.localizedBundle.localizedString(forKey: key, value: key, table: "Providers")
}

struct AIProviderPicker: View {
    @Bindable var chat: AgentChatSession
    @State private var profiles = AIProviderStore.profiles()
    var body: some View {
        HStack(spacing: 8) {
            Picker(providerText("Provider"), selection: Binding(get: { chat.providerProfile.id }, set: { id in
                guard let profile = AIProviderStore.profiles().first(where: { $0.id == id }) else { return }
                do { try chat.useProvider(profile) } catch { chat.errorMessage = error.localizedDescription }
            })) {
                ForEach(profiles) { Text($0.name).tag($0.id) }
            }.labelsHidden()
            if !chat.models.isEmpty {
                Menu {
                    ForEach(chat.models) { model in Button(model.title) { chat.selectModel(model.id) } }
                } label: { Text(chat.modelID).font(.caption).lineLimit(1) }
            }
        }
        .disabled(!chat.canChangeProvider)
        .onAppear { profiles = AIProviderStore.profiles() }
        .onChange(of: chat.providerProfile) { _, _ in profiles = AIProviderStore.profiles() }
    }
}

/// Edits a draft; an endpoint or API key is never changed underneath an in-flight turn.
struct AIProviderSettings: View {
    @Bindable var chat: AgentChatSession
    @State private var profiles = AIProviderStore.profiles()
    @State private var profile = AIProviderProfile.codex
    @State private var key = ""
    @State private var isFetching = false
    @State private var message: String?
    @State private var confirmsDelete = false
    @State private var requestGeneration = UUID()
    @State private var fetchTask: Task<Void, Never>?
    private var saved: AIProviderProfile? { profiles.first { $0.id == profile.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(providerText("Models and API providers")).font(.headline)
            Picker(providerText("Configuration"), selection: Binding(get: { profile.id }, set: { id in
                if let value = profiles.first(where: { $0.id == id }) { choose(value) }
            })) {
                ForEach(profiles) { Text($0.name).tag($0.id) }
                if !profiles.contains(where: { $0.id == profile.id }) { Text(profile.name).tag(profile.id) }
            }
            HStack {
                Button(providerText("Add DeepSeek")) { choose(.deepSeek()) }
                Button(providerText("Add custom API")) { choose(.custom()) }
            }
            if profile.isCodex {
                Text(providerText("Codex / ChatGPT keeps its existing account login. Use the account controls below.")).font(.caption).foregroundStyle(.secondary)
                Button(providerText("Use this provider")) { activate(profile) }
            } else {
                TextField(providerText("Name"), text: $profile.name)
                TextField(providerText("Base URL (include port when needed)"), text: $profile.baseURL)
                    .help("https://api.deepseek.com  ·  http://127.0.0.1:1234/v1")
                SecureField(providerText(saved == nil ? "API key" : "API key (blank keeps the saved key)"), text: $key)
                HStack {
                    TextField(providerText("Model ID"), text: $profile.model)
                    if !profile.knownModels.isEmpty {
                        Menu(providerText("Choose model")) {
                            ForEach(profile.knownModels, id: \.self) { model in Button(model) { profile.model = model } }
                        }.fixedSize()
                    }
                }
                if profile.kind != .deepseek {
                    Toggle(providerText("This model supports image input"), isOn: $profile.supportsImages).font(.caption)
                }
                HStack {
                    Button(providerText("Fetch models")) { fetchModels() }.disabled(isFetching)
                    if isFetching { ProgressView().controlSize(.small) }
                    Spacer()
                    if saved != nil { Button(providerText("Delete"), role: .destructive) { confirmsDelete = true } }
                    Button(providerText("Save and use")) { save() }.buttonStyle(.borderedProminent)
                }
                Text(providerText("Responses-compatible APIs only. Fetching the model list does not run paid inference. A manually entered model ID also works."))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(providerText("Keys are stored in macOS Keychain. Changing the API address requires entering the key again. Switching providers does not transfer previous chat or images."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let message { Text(providerText(message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(!chat.canChangeProvider)
        .onAppear { profiles = AIProviderStore.profiles(); choose(chat.providerProfile) }
        .onDisappear { fetchTask?.cancel(); key = "" }
        .alert(providerText("Delete this provider and its saved API key?"), isPresented: $confirmsDelete) {
            Button(providerText("Cancel"), role: .cancel) { }
            Button(providerText("Delete"), role: .destructive) { delete() }
        }
    }
    private func choose(_ value: AIProviderProfile) {
        requestGeneration = UUID(); fetchTask?.cancel(); fetchTask = nil
        isFetching = false; profile = value; key = ""; message = nil
    }
    private func activate(_ value: AIProviderProfile) {
        do { try chat.useProvider(value); message = "Provider selected. Connect or send a message to start." }
        catch { message = error.localizedDescription }
    }
    private func credential() throws -> String {
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return key.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let saved {
            let old = try AIProviderProfile.normalizedEndpoint(saved.baseURL)
            let new = try AIProviderProfile.normalizedEndpoint(profile.baseURL)
            guard old == new else { throw AIProviderError("Enter the API key again when changing the API address.") }
            return try AIProviderSecrets.read(profile.id) ?? ""
        }
        return ""
    }
    private func save() {
        do {
            var value = try profile.validated()
            let secret = try credential()
            if value.kind == .deepseek, secret.isEmpty { throw AIProviderError("Enter a DeepSeek API key in provider settings.") }
            if let old = saved, old.baseURL != value.baseURL || old.model != value.model || old.supportsImages != value.supportsImages || !key.isEmpty {
                value.contextID = UUID()
            }
            if !key.isEmpty { try AIProviderSecrets.write(secret, for: value.id) }
            try AIProviderStore.save(value)
            profiles = AIProviderStore.profiles(); profile = value; key = ""
            activate(value)
        } catch { message = error.localizedDescription }
    }
    private func delete() {
        do {
            if chat.providerProfile.id == profile.id { try chat.useProvider(.codex) }
            try AIProviderSecrets.delete(profile.id); try AIProviderStore.delete(profile.id)
            profiles = AIProviderStore.profiles(); choose(.codex)
        } catch { message = error.localizedDescription }
    }
    private func fetchModels() {
        do {
            let secret = try credential(), snapshot = profile, token = UUID()
            requestGeneration = token; isFetching = true; message = nil
            fetchTask = Task { @MainActor in
                defer { if requestGeneration == token { isFetching = false } }
                do {
                    let models = try await AIProviderHTTP.models(profile: snapshot, apiKey: secret)
                    guard requestGeneration == token, profile.baseURL == snapshot.baseURL, !Task.isCancelled else { return }
                    profile.knownModels = models
                    if profile.model.isEmpty { profile.model = models.first ?? "" }
                    message = "Model list loaded. Save and use this configuration to start chatting."
                } catch {
                    if requestGeneration == token, !Task.isCancelled { message = error.localizedDescription }
                }
            }
        } catch { message = error.localizedDescription }
    }
}
