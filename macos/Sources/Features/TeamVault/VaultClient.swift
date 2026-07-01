import Foundation

/// Async HTTP client for the Vault API. Matches the app's existing networking
/// style (direct `URLSession.shared` + async/await + throwing).
struct VaultClient {
    var baseURL: URL = VaultConfig.baseURL
    var token: String?

    // MARK: Request plumbing

    private func makeRequest(_ path: String, method: String = "GET", json body: Encodable? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VaultError("Invalid URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VaultError("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw VaultError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VaultError(Self.errorMessage(from: data, status: http.statusCode))
        }
        return data
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return "Request failed (HTTP \(status))"
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw VaultError("Unexpected response: \(error.localizedDescription)") }
    }

    // MARK: Endpoints

    func devLogin(email: String) async throws -> DevLoginResponse {
        let req = try makeRequest("/auth/dev-login", method: "POST", json: ["email": email])
        return try decode(DevLoginResponse.self, try await send(req))
    }

    func me() async throws -> MeResponse {
        try decode(MeResponse.self, try await send(try makeRequest("/me")))
    }

    func registerPublicKey(_ publicKeyBase64: String) async throws {
        let req = try makeRequest("/me/public-key", method: "PUT", json: ["publicKey": publicKeyBase64])
        _ = try await send(req)
    }

    func teams() async throws -> [TeamSummary] {
        try [TeamSummary].decode(from: try await send(try makeRequest("/me/teams")))
    }

    private func teamBase(_ t: TeamSummary) -> String {
        "/orgs/\(t.org.id)/workspaces/\(t.workspace.id)/teams/\(t.id)"
    }

    func myWrappedKey(for team: TeamSummary) async throws -> WrappedKeyResponse {
        try decode(WrappedKeyResponse.self, try await send(try makeRequest("\(teamBase(team))/keys/me")))
    }

    func vaultBlob(for team: TeamSummary) async throws -> VaultBlobResponse {
        try decode(VaultBlobResponse.self, try await send(try makeRequest("\(teamBase(team))/vault")))
    }

    func putVaultBlob(for team: TeamSummary, ciphertextBase64: String, baseVersion: Int) async throws -> VaultBlobResponse {
        let req = try makeRequest("\(teamBase(team))/vault", method: "PUT", json: VaultBlobPut(ciphertext: ciphertextBase64, baseVersion: baseVersion))
        return try decode(VaultBlobResponse.self, try await send(req))
    }

    func putWrappedKeys(for team: TeamSummary, dekVersion: Int, keys: [WrappedKeyEntry]) async throws {
        let req = try makeRequest("\(teamBase(team))/keys", method: "POST", json: WrappedKeysPut(dekVersion: dekVersion, keys: keys))
        _ = try await send(req)
    }

    // MARK: Files

    func listFiles(for team: TeamSummary) async throws -> [TeamFileMeta] {
        let data = try await send(try makeRequest("\(teamBase(team))/files"))
        return try decode(FilesEnvelope.self, data).files
    }

    func downloadFile(for team: TeamSummary, fileID: String) async throws -> TeamFileDownload {
        try decode(TeamFileDownload.self, try await send(try makeRequest("\(teamBase(team))/files/\(fileID)")))
    }

    func uploadFile(for team: TeamSummary, name: String, contentType: String, dekVersion: Int, ciphertextBase64: String) async throws {
        let req = try makeRequest("\(teamBase(team))/files", method: "POST",
                                  json: FileUpload(name: name, contentType: contentType, dekVersion: dekVersion, ciphertext: ciphertextBase64))
        _ = try await send(req)
    }
}

// MARK: - Request bodies

private struct VaultBlobPut: Encodable {
    let ciphertext: String
    let baseVersion: Int
}

struct WrappedKeyEntry: Encodable {
    let userId: String
    let wrappedKey: String
}

private struct WrappedKeysPut: Encodable {
    let dekVersion: Int
    let keys: [WrappedKeyEntry]
}

private struct FileUpload: Encodable {
    let name: String
    let contentType: String
    let dekVersion: Int
    let ciphertext: String
}

/// Type-erased Encodable so the client can take a heterogeneous JSON body.
private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
