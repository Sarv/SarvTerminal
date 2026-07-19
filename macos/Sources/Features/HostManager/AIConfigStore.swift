import Foundation

/// User's AI command-assist configuration. Persisted encrypted at rest (the
/// blob contains BYOK API keys) via `EncryptedStore`, mirroring `SnippetsStore`.
///
/// Per-provider `models` / `baseURLs` / `apiKeys` are keyed by
/// `AIProviderKind.rawValue` so switching the active provider never discards
/// the others' settings.
struct AIConfig: Codable, Equatable {
    var enabled: Bool = false
    var provider: AIProviderKind = .anthropic
    var models: [String: String] = [:]
    var baseURLs: [String: String] = [:]
    var apiKeys: [String: String] = [:]

    func model(for kind: AIProviderKind) -> String {
        let v = (models[kind.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? kind.defaultModel : v
    }

    func baseURL(for kind: AIProviderKind) -> String {
        let v = (baseURLs[kind.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? kind.defaultBaseURL : v
    }

    func apiKey(for kind: AIProviderKind) -> String {
        apiKeys[kind.rawValue] ?? ""
    }
}

/// Owns the persisted AI config. Storage: `~/.config/sarvterminal/ai.json`
/// (AES-GCM encrypted). Singleton so the command-finished hook and the settings
/// pane share one source of truth.
final class AIConfigStore: ObservableObject {
    static let shared = AIConfigStore()

    /// The whole config. Mutations from the settings UI persist (debounced onto
    /// the IO queue). Reading is cheap and safe from the main thread.
    @Published var config: AIConfig {
        didSet { if config != oldValue { persist() } }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "AIConfigStore.io", qos: .utility)

    private init() {
        fileURL = AppPaths.configDir.appendingPathComponent("ai.json")

        // Encrypted at rest; legacy plaintext (unlikely — new feature) migrated once.
        let decoder = JSONDecoder()
        switch EncryptedStore.read(AIConfig.self, from: fileURL, decoder: decoder) {
        case .none, .failed:
            config = AIConfig()
        case .loaded(let decoded):
            config = decoded
        case .migrated(let decoded):
            config = decoded
            persist()
        }
    }

    // MARK: - Derived

    /// Convenience: is the feature switched on?
    var enabled: Bool { config.enabled }

    /// The settings for the active provider, or `nil` if it isn't usable yet
    /// (a cloud provider with no key). `nil` means "don't offer AI assist".
    var currentSettings: AIProviderSettings? {
        let kind = config.provider
        let key = config.apiKey(for: kind)
        if kind.requiresAPIKey && key.isEmpty { return nil }
        return AIProviderSettings(
            kind: kind,
            model: config.model(for: kind),
            baseURL: config.baseURL(for: kind),
            apiKey: key
        )
    }

    // MARK: - IO

    private func persist() {
        let snapshot = config
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            try? EncryptedStore.write(snapshot, to: url, encoder: encoder)
        }
    }
}
