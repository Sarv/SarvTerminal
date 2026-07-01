import Foundation

/// Error surfaced by the team-vault client/crypto. Conforms to LocalizedError
/// so it renders nicely in the UI.
struct VaultError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - API DTOs (mirror the Vault API responses)

struct VaultUser: Codable {
    let id: String
    let email: String
    let displayName: String?
    let platformRole: String?
}

struct DevLoginResponse: Codable {
    let token: String
    let user: VaultUser
}

struct MeResponse: Codable {
    let id: String
    let email: String
    let displayName: String?
    let publicKey: String?
    let hasPublicKey: Bool
}

struct TeamRef: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct WorkspaceRef: Codable, Hashable {
    let id: String
    let name: String
}

struct OrgRef: Codable, Hashable {
    let id: String
    let name: String
}

/// One row from `GET /me/teams` — carries the full org→workspace→team path
/// needed to build the nested vault endpoints.
struct TeamSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let dekVersion: Int
    let workspace: WorkspaceRef
    let org: OrgRef
}

private struct TeamsEnvelope: Codable { let teams: [TeamSummary] }

struct WrappedKeyResponse: Codable {
    let dekVersion: Int
    let wrappedKey: String
}

struct VaultBlobResponse: Codable {
    let version: Int
    let ciphertext: String?
}

/// The plaintext payload stored (encrypted) in a team vault: the team's hosts
/// and groups, in the same shape the local stores use.
struct TeamVaultPayload: Codable {
    var hosts: [SavedHost]
    var groups: [HostGroup]
}

extension Array where Element == TeamSummary {
    static func decode(from data: Data) throws -> [TeamSummary] {
        try JSONDecoder().decode(TeamsEnvelope.self, from: data).teams
    }
}

// MARK: - Files

struct TeamFileMeta: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let contentType: String
    let sizeBytes: Int
    let dekVersion: Int
    let createdAt: String?
}

struct TeamFileDownload: Codable {
    let id: String
    let name: String
    let contentType: String
    let dekVersion: Int
    let ciphertext: String
}

struct FilesEnvelope: Codable { let files: [TeamFileMeta] }
