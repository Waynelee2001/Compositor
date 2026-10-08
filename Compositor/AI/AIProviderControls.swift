import SwiftUI

struct AIProviderControls: View {
    @Bindable var chat: AgentChatSession
    @State private var editing: AIProviderProfile?
    private var store: AIProviderStore { .shared }
    private var modelIDs: [String] {
        let source = chat.provider.kind == .codex ? chat.models.map(\.id) : chat.provider.models
        return Array(Set(source + [chat.modelID])).sorted()
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker(codexText("Provider"), selection: Binding(get: { chat.provider.id }, set: { chat.chooseProvider($0) })) {
                    ForEach(store.profiles) { Text(codexText($0.name)).tag($0.id) }
                }.pickerStyle(.menu)
                Button { editing = .custom() } label: { Image(systemName: "plus") }
                    .help(codexText("Add provider"))
                if chat.provider.kind != .codex {
                    Button { editing = chat.provider } label: { Image(systemName: "pencil") }
                        .help(codexText("Edit provider"))
                }
            }
            Picker(codexText("Model"), selection: Binding(get: { chat.modelID }, set: { chat.chooseModel($0) })) {
                ForEach(modelIDs, id: \.self) { id in
                    Text(id.isEmpty ? codexText("Automatic") : id).tag(id)
                }
            }.pickerStyle(.menu)
        }.font(.caption).disabled(!chat.canSwitchProvider)
        .sheet(item: $editing) { profile in
            AIProviderEditor(profile: profile) { id in chat.chooseProvider(id, force: true) }
        }
    }
}

/// Deliberately small: one endpoint, one key, a model choice, no routes, proxies, or global CLI configuration.
struct AIProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: AIProviderProfile
    @State private var key = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var confirmsTest = false
    @State private var confirmsDeleteKey = false
    let onSave: (String) -> Void
    init(profile: AIProviderProfile, onSave: @escaping (String) -> Void) {
        _profile = State(initialValue: profile); self.onSave = onSave
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(codexText("Provider settings")).font(.title2.weight(.semibold))
            Form {
                TextField(codexText("Name"), text: $profile.name)
                TextField(codexText("API base URL (including port if needed)"), text: $profile.baseURL)
                SecureField(codexText("API key (leave empty to keep saved key)"), text: $key)
                TextField(codexText("Model ID"), text: $profile.model)
                if !profile.models.isEmpty {
                    Picker(codexText("Available models"), selection: $profile.model) {
                        ForEach(Array(Set(profile.models + [profile.model])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle(codexText("This model supports image input"), isOn: $profile.supportsImages)
            }.textFieldStyle(.roundedBorder)
            Text(codexText("Responses API compatible services only. DeepSeek V4.1 Flash uses deepseek-flash. For a proxy, include its /v1 path when required."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(codexText("Fetch models")) { run {
                    profile.models = try await AIProviderClient.models(for: profile, key: credential())
                    message = "Model list loaded. Choose a model or enter its ID manually."
                } }
                Button(codexText("Test model…")) { confirmsTest = true }
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let message { Text(codexText(message)).font(.caption).textSelection(.enabled) }
            Text(codexText("Keys stay in macOS Keychain. Switching provider or model opens its separate conversation and turns canvas sharing off."))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(codexText("Delete saved key…"), role: .destructive) { confirmsDeleteKey = true }
                Spacer()
                Button(codexText("Cancel")) { key = ""; dismiss() }
                Button(codexText("Save and select")) {
                    do {
                        let value = try profile.validated()
                        try AIProviderStore.shared.save(value, key: key.isEmpty ? nil : key)
                        key = ""; onSave(value.id); dismiss()
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 500).disabled(isWorking)
        .modifier(AppAppearanceModifier())
        .alert(codexText("Test this model?"), isPresented: $confirmsTest) {
            Button(codexText("Cancel"), role: .cancel) { }
            Button(codexText("Run test")) { run {
                try await AIProviderClient.test(profile, key: credential())
                message = "The Responses API test completed. Image quality and editor tool use still need a real conversation test."
            } }
        } message: { Text(codexText("This sends a short test prompt to the entered address and may incur a small API charge. No photo or conversation is included.")) }
        .alert(codexText("Delete this provider's saved key?"), isPresented: $confirmsDeleteKey) {
            Button(codexText("Cancel"), role: .cancel) { }
            Button(codexText("Delete"), role: .destructive) {
                do { try AIProviderKeys.remove(profile.keychainAccount()); key = ""; onSave(profile.id); message = "Saved key deleted." }
                catch { message = error.localizedDescription }
            }
        }
    }
    private func credential() throws -> String {
        key.isEmpty ? (try AIProviderKeys.read(profile.keychainAccount()) ?? "") : key
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true; message = nil
        Task {
            defer { isWorking = false }
            do { try await operation() } catch { message = error.localizedDescription }
        }
    }
}
