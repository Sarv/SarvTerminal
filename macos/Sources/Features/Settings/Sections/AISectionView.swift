import SwiftUI

/// Settings → AI. Configure the AI command-assist provider (Claude / OpenAI /
/// local Ollama), a bring-your-own API key (stored encrypted on-device, never
/// synced), and the model. When a command fails, the app offers to explain it
/// and suggest a fix using the chosen model.
struct AISectionView: View {
    @ObservedObject private var store = AIConfigStore.shared

    /// Per-provider key entry. The stored key is never echoed back — the field
    /// shows a placeholder when one is saved and only overwrites on Save.
    @State private var keyDraft = ""

    /// Models fetched from the active provider (empty until loaded).
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    private var provider: AIProviderKind { store.config.provider }
    private var hasSavedKey: Bool { !store.config.apiKey(for: provider).isEmpty }

    /// Reloads the model list whenever the provider or key-saved state changes.
    private var reloadKey: String { "\(provider.rawValue)#\(hasSavedKey)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            enableCard
            if store.config.enabled {
                providerCard
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .onChange(of: provider) { _ in
            keyDraft = ""
            testState = .idle
        }
        .task(id: reloadKey) {
            await loadModels()
        }
    }

    // MARK: - Cards

    private var enableCard: some View {
        SettingsCard(title: "AI Command Assist") {
            settingsRow("Enable") {
                Toggle("", isOn: Binding(
                    get: { store.config.enabled },
                    set: { store.config.enabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsDivider()
            Text("When a command exits with a non-zero status, Sarv Terminal offers to explain the failure and suggest a fix using your chosen model.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
        }
    }

    private var providerCard: some View {
        SettingsCard(title: "Provider & Model") {
            // Provider
            settingsRow("Provider") {
                Picker("", selection: Binding(
                    get: { store.config.provider },
                    set: { store.config.provider = $0 }
                )) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)
            }
            SettingsDivider()

            // API key (cloud providers only)
            if provider.requiresAPIKey {
                settingsRow("API key", alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField(hasSavedKey ? "•••••• saved — type to replace" : "Paste your API key",
                                        text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                            Button("Save") { saveKey() }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if hasSavedKey {
                                Button("Clear") { clearKey() }
                            }
                        }
                        Label("Stored encrypted on this Mac. Never synced, backed up, or sent anywhere except \(provider.displayName).",
                              systemImage: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                        if let hint = provider.keyHint {
                            Text("Get a key: \(hint)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsDivider()
            }

            // Model (dropdown fetched from the provider)
            settingsRow("Model", alignment: .top) {
                modelControl
            }
            SettingsDivider()

            // Endpoint (advanced)
            settingsRow("Endpoint") {
                TextField(provider.defaultBaseURL, text: baseURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
            }
            SettingsDivider()

            // Test
            settingsRow("Test", alignment: .center) {
                testControl
            }
        }
    }

    // MARK: - Model control

    /// Fetched models, with the currently-saved value kept even if it isn't in
    /// the list (so a prior choice is never silently dropped).
    private var modelOptions: [String] {
        let current = store.config.models[provider.rawValue] ?? ""
        if !current.isEmpty && !models.contains(current) {
            return [current] + models
        }
        return models
    }

    @ViewBuilder private var modelControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if models.isEmpty {
                    // Not loaded yet (or none returned) — free text as a fallback.
                    TextField(provider.defaultModel, text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button {
                        Task { await loadModels() }
                    } label: {
                        if loadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load models")
                        }
                    }
                    .disabled(loadingModels || store.currentSettings == nil)
                } else {
                    Picker("", selection: modelBinding) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                    Button {
                        Task { await loadModels() }
                    } label: {
                        if loadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(loadingModels)
                    .help("Refresh model list")
                }
            }
            if let modelError {
                Text(modelError)
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if provider.requiresAPIKey && !hasSavedKey {
                Text("Save your API key to load the available models.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Test control

    @ViewBuilder private var testControl: some View {
        HStack(spacing: 12) {
            Button {
                runTest()
            } label: {
                if testState == .testing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Text("Send a test request")
                }
            }
            .disabled(testState == .testing || store.currentSettings == nil)

            switch testState {
            case .idle, .testing:
                EmptyView()
            case .ok:
                Label("Working", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 12))
            case .failed(let msg):
                Label(msg, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.system(size: 12))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Bindings

    private var modelBinding: Binding<String> {
        Binding(
            get: { store.config.models[provider.rawValue] ?? "" },
            set: { store.config.models[provider.rawValue] = $0 }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { store.config.baseURLs[provider.rawValue] ?? "" },
            set: { store.config.baseURLs[provider.rawValue] = $0 }
        )
    }

    // MARK: - Actions

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        store.config.apiKeys[provider.rawValue] = key
        keyDraft = ""
        testState = .idle
        // reloadKey changes → .task reloads models with the new key.
    }

    private func clearKey() {
        store.config.apiKeys[provider.rawValue] = nil
        keyDraft = ""
        testState = .idle
        models = []
    }

    @MainActor
    private func loadModels() async {
        models = []
        modelError = nil
        guard let settings = store.currentSettings else { return }  // cloud w/o key
        loadingModels = true
        defer { loadingModels = false }
        do {
            let list = try await settings.listModels()
            models = list
            // Default the model if none chosen yet.
            if (store.config.models[provider.rawValue] ?? "").isEmpty, let first = list.first {
                store.config.models[provider.rawValue] = first
            }
        } catch {
            modelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runTest() {
        guard let settings = store.currentSettings else { return }
        testState = .testing
        let client = settings.makeClient()
        Task { @MainActor in
            do {
                _ = try await client.complete(AICompletionRequest(
                    system: "You are a connectivity check.",
                    messages: [AIMessage(role: .user, content: "Reply with the single word: OK")],
                    maxTokens: 16
                ))
                testState = .ok
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testState = .failed(msg)
            }
        }
    }
}
