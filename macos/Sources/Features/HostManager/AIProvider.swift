import Foundation

/// Which LLM backend the AI command-assist feature talks to.
///
/// All three are plain HTTPS/JSON chat APIs, so we hit them directly with
/// `URLSession` (there is no first-party Swift SDK for any of them). Keys are
/// bring-your-own and stored encrypted at rest — see `AIConfigStore`.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "OpenAI"
        case .ollama:    return "Ollama (local)"
        }
    }

    /// Ollama runs locally and needs no key; the cloud providers are BYOK.
    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .ollama:             return false
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openai:    return "gpt-4o"
        case .ollama:    return "llama3.1"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai:    return "https://api.openai.com"
        case .ollama:    return "http://localhost:11434"
        }
    }

    /// Where the user gets a key (shown as a hint under the key field).
    var keyHint: String? {
        switch self {
        case .anthropic: return "console.anthropic.com → API Keys"
        case .openai:    return "platform.openai.com → API Keys"
        case .ollama:    return nil
        }
    }
}

/// A single chat turn handed to a provider.
struct AIMessage {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
}

/// One completion request, provider-agnostic. The concrete client maps this
/// onto each backend's wire format.
struct AICompletionRequest {
    var system: String?
    var messages: [AIMessage]
    var maxTokens: Int = 1024
}

/// Errors surfaced to the UI. Messages are user-facing, so keep them plain.
enum AIProviderError: LocalizedError {
    case missingAPIKey(AIProviderKind)
    case badBaseURL(String)
    case http(status: Int, body: String)
    case emptyResponse
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let kind):
            return "No API key set for \(kind.displayName). Add one in Settings → AI."
        case .badBaseURL(let s):
            return "Invalid base URL: \(s)"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : " — \(trimmed.prefix(300))"
            return "Request failed (HTTP \(status))\(detail)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .decoding(let s):
            return "Couldn't read the model response: \(s)"
        case .transport(let s):
            return "Network error: \(s)"
        }
    }
}

/// One concrete backend. `complete` performs a single non-streaming request and
/// returns the assistant's text. Non-streaming keeps the popover simple; the
/// responses here are short (an explanation + a suggested fix).
protocol AIProviderClient {
    func complete(_ request: AICompletionRequest) async throws -> String
}

/// Everything a client needs to talk to one backend: which provider, which
/// model, its base URL, and (for cloud providers) the BYOK key.
struct AIProviderSettings {
    var kind: AIProviderKind
    var model: String
    var baseURL: String
    var apiKey: String

    /// Build the right client for `kind`.
    func makeClient(session: URLSession = .shared) -> AIProviderClient {
        switch kind {
        case .anthropic: return AnthropicClient(settings: self, session: session)
        case .openai:    return OpenAIClient(settings: self, session: session)
        case .ollama:    return OllamaClient(settings: self, session: session)
        }
    }
}

// MARK: - Shared HTTP helpers

private enum AIHTTP {
    /// POST `body` to `url` with the given headers and return the raw data,
    /// mapping non-2xx and transport failures onto `AIProviderError`.
    static func post(_ url: URL,
                     headers: [String: String],
                     body: Data,
                     session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AIProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.http(status: http.statusCode, body: text)
        }
        return data
    }

    /// GET `url` with the given headers, mapping failures onto `AIProviderError`.
    static func get(_ url: URL,
                    headers: [String: String],
                    session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AIProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.http(status: http.statusCode, body: text)
        }
        return data
    }

    /// Pull a value at a JSON key path out of a decoded dictionary tree.
    static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIProviderError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Model listing

extension AIProviderSettings {
    /// Fetch the provider's available model IDs so the UI can offer a dropdown
    /// instead of free text. Cloud providers require the key; Ollama is local.
    func listModels(session: URLSession = .shared) async throws -> [String] {
        switch kind {
        case .anthropic: return try await anthropicModels(session)
        case .openai:    return try await openAIModels(session)
        case .ollama:    return try await ollamaModels(session)
        }
    }

    private func anthropicModels(_ session: URLSession) async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(.anthropic) }
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/models") else {
            throw AIProviderError.badBaseURL(baseURL)
        }
        let data = try await AIHTTP.get(url, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ], session: session)
        // { "data": [ { "id": "claude-opus-4-8", ... } ] }
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw AIProviderError.decoding("unexpected models response")
        }
        return list.compactMap { $0["id"] as? String }
    }

    private func openAIModels(_ session: URLSession) async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(.openai) }
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/models") else {
            throw AIProviderError.badBaseURL(baseURL)
        }
        let data = try await AIHTTP.get(url, headers: [
            "Authorization": "Bearer \(apiKey)",
        ], session: session)
        // { "data": [ { "id": "gpt-4o", ... } ] } — filter to chat-capable models.
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw AIProviderError.decoding("unexpected models response")
        }
        let ids = list.compactMap { $0["id"] as? String }
        let chat = ids.filter { id in
            id.hasPrefix("gpt") || id.hasPrefix("chatgpt") || id.range(of: #"^o\d"#, options: .regularExpression) != nil
        }
        return (chat.isEmpty ? ids : chat).sorted()
    }

    private func ollamaModels(_ session: URLSession) async throws -> [String] {
        guard let url = URL(string: baseURL)?.appendingPathComponent("api/tags") else {
            throw AIProviderError.badBaseURL(baseURL)
        }
        let data = try await AIHTTP.get(url, headers: [:], session: session)
        // { "models": [ { "name": "llama3.1:latest", ... } ] }
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let list = root["models"] as? [[String: Any]] else {
            throw AIProviderError.decoding("unexpected models response")
        }
        return list.compactMap { $0["name"] as? String }.sorted()
    }
}

// MARK: - Anthropic (Messages API)

private struct AnthropicClient: AIProviderClient {
    let settings: AIProviderSettings
    let session: URLSession

    func complete(_ request: AICompletionRequest) async throws -> String {
        guard !settings.apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey(.anthropic)
        }
        guard let url = URL(string: settings.baseURL)?.appendingPathComponent("v1/messages") else {
            throw AIProviderError.badBaseURL(settings.baseURL)
        }

        // Anthropic keeps `system` top-level; only user/assistant go in messages.
        var payload: [String: Any] = [
            "model": settings.model,
            "max_tokens": request.maxTokens,
            "messages": request.messages
                .filter { $0.role != .system }
                .map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if let system = request.system, !system.isEmpty {
            payload["system"] = system
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await AIHTTP.post(
            url,
            headers: [
                "x-api-key": settings.apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: body,
            session: session
        )

        // { "content": [ { "type": "text", "text": "..." }, ... ] }
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AIProviderError.decoding("unexpected response shape")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw AIProviderError.emptyResponse }
        return text
    }
}

// MARK: - OpenAI (Chat Completions)

private struct OpenAIClient: AIProviderClient {
    let settings: AIProviderSettings
    let session: URLSession

    func complete(_ request: AICompletionRequest) async throws -> String {
        guard !settings.apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey(.openai)
        }
        guard let url = URL(string: settings.baseURL)?.appendingPathComponent("v1/chat/completions") else {
            throw AIProviderError.badBaseURL(settings.baseURL)
        }

        // OpenAI folds `system` into the message array.
        var messages: [[String: String]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        let payload: [String: Any] = [
            "model": settings.model,
            "max_tokens": request.maxTokens,
            "messages": messages,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await AIHTTP.post(
            url,
            headers: ["Authorization": "Bearer \(settings.apiKey)"],
            body: body,
            session: session
        )

        // { "choices": [ { "message": { "content": "..." } } ] }
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIProviderError.decoding("unexpected response shape")
        }
        guard !text.isEmpty else { throw AIProviderError.emptyResponse }
        return text
    }
}

// MARK: - Ollama (local chat)

private struct OllamaClient: AIProviderClient {
    let settings: AIProviderSettings
    let session: URLSession

    func complete(_ request: AICompletionRequest) async throws -> String {
        guard let url = URL(string: settings.baseURL)?.appendingPathComponent("api/chat") else {
            throw AIProviderError.badBaseURL(settings.baseURL)
        }

        var messages: [[String: String]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        let payload: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "stream": false,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await AIHTTP.post(
            url,
            headers: [:],
            body: body,
            session: session
        )

        // { "message": { "content": "..." } }
        guard let root = try AIHTTP.json(data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIProviderError.decoding("unexpected response shape")
        }
        guard !text.isEmpty else { throw AIProviderError.emptyResponse }
        return text
    }
}
