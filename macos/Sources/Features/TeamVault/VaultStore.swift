import Foundation
import CryptoKit
import SwiftUI

/// Which team's hosts the unified browser shows.
enum VaultFilter: Equatable, Hashable {
    case all
    case team(String) // team id
}

/// Observable state + actions for team vaults. Supports multiple signed-in
/// accounts; the active account drives the visible teams. Team data is
/// end-to-end encrypted and fetched/decrypted on demand — never written to
/// disk. All UI state mutates on the main actor.
@MainActor
final class VaultStore: ObservableObject {
    static let shared = VaultStore()

    @Published private(set) var accounts: [VaultAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var teams: [TeamSummary] = []

    // teamID → decrypted vault payload (hosts + groups), loaded lazily.
    @Published private(set) var teamPayloads: [String: TeamVaultPayload] = [:]
    @Published private(set) var teamErrors: [String: String] = [:]
    @Published private(set) var loadingTeamIDs: Set<String> = []

    // teamID → files shared in that team (metadata only; bytes fetched on download).
    @Published private(set) var filesByTeam: [String: [TeamFileMeta]] = [:]
    @Published private(set) var fileErrors: [String: String] = [:]

    @Published var filter: VaultFilter = .all
    @Published var showingAddAccount = false

    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    // Cached team DEKs (unwrapped) so file/host ops don't re-fetch keys.
    private var dekCache: [String: SymmetricKey] = [:]

    private init() {
        accounts = VaultKeychain.accounts()
        activeAccountID = VaultKeychain.active()?.id
    }

    // MARK: Derived

    var isAuthenticated: Bool { activeAccountID != nil }
    var activeAccount: VaultAccount? { accounts.first { $0.id == activeAccountID } }
    var activeEmail: String? { activeAccount?.email }

    private var client: VaultClient { VaultClient(token: activeAccount?.token) }

    private func activePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let b64 = activeAccount?.privateKey else { throw VaultError("No device key — sign in again") }
        return try VaultCrypto.privateKey(fromBase64: b64)
    }

    // MARK: Accounts / sign-in

    /// Dev/email sign-in (local). Adds or refreshes an account.
    func login(email rawEmail: String) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return }
        run("Signing in…") {
            let res = try await VaultClient().devLogin(email: email)
            try await self.adoptSession(userID: res.user.id, email: res.user.email, token: res.token)
        }
    }

    /// Manual sign-in: paste an auth token obtained from the Sarv login page.
    /// Validated by calling `/me` with it.
    func loginWithToken(_ rawToken: String) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        run("Verifying token…") {
            let me = try await VaultClient(token: token).me()
            try await self.adoptSession(userID: me.id, email: me.email, token: token)
        }
    }

    /// Common path: persist the account (reusing/minting a keypair), register
    /// our public key, make it active, and load teams.
    private func adoptSession(userID: String, email: String, token: String) async throws {
        let existing = VaultKeychain.accounts().first { $0.id == userID }
        let privB64 = existing?.privateKey ?? VaultCrypto.base64(VaultCrypto.generatePrivateKey())
        let acct = VaultAccount(id: userID, email: email, token: token, privateKey: privB64)
        VaultKeychain.upsert(acct, makeActive: true)

        let key = try VaultCrypto.privateKey(fromBase64: privB64)
        try await VaultClient(token: token).registerPublicKey(VaultCrypto.publicKeyBase64(key))

        await MainActor.run {
            self.accounts = VaultKeychain.accounts()
            self.activeAccountID = userID
            self.resetTeamState()
            self.showingAddAccount = false
        }
        try await self.refreshTeamsThrowing()
    }

    func switchAccount(_ id: String) {
        VaultKeychain.setActive(id)
        activeAccountID = id
        accounts = VaultKeychain.accounts()
        resetTeamState()
        refreshTeams()
    }

    func signOut(_ id: String) {
        VaultKeychain.remove(id)
        accounts = VaultKeychain.accounts()
        activeAccountID = VaultKeychain.active()?.id
        resetTeamState()
        if isAuthenticated { refreshTeams() }
    }

    private func resetTeamState() {
        teams = []
        teamPayloads = [:]
        teamErrors = [:]
        loadingTeamIDs = []
        filesByTeam = [:]
        fileErrors = [:]
        dekCache = [:]
        filter = .all
        statusMessage = nil
    }

    // MARK: Teams

    func refreshTeams() {
        guard isAuthenticated else { return }
        run("Loading teams…") { try await self.refreshTeamsThrowing() }
    }

    private func refreshTeamsThrowing() async throws {
        let teams = try await client.teams()
        await MainActor.run { self.teams = teams }
    }

    // MARK: DEK + payload

    private func dek(for team: TeamSummary) async throws -> SymmetricKey {
        if let cached = dekCache[team.id] { return cached }
        let priv = try activePrivateKey()
        let wrapped = try await client.myWrappedKey(for: team)
        let key = try VaultCrypto.unwrapDEK(wrapped.wrappedKey, with: priv)
        await MainActor.run { self.dekCache[team.id] = key }
        return key
    }

    func ensureHostsLoaded(for team: TeamSummary) {
        guard teamPayloads[team.id] == nil, !loadingTeamIDs.contains(team.id) else { return }
        loadingTeamIDs.insert(team.id)
        Task {
            do {
                let key = try await self.dek(for: team)
                let blob = try await self.client.vaultBlob(for: team)
                var payload = TeamVaultPayload(hosts: [], groups: [])
                if let ct = blob.ciphertext, let data = Data(base64Encoded: ct) {
                    let plaintext = try VaultCrypto.openBlob(data, dek: key)
                    payload = try JSONDecoder().decode(TeamVaultPayload.self, from: plaintext)
                }
                await MainActor.run {
                    self.teamPayloads[team.id] = payload
                    self.teamErrors[team.id] = nil
                    self.loadingTeamIDs.remove(team.id)
                }
            } catch {
                await MainActor.run {
                    self.teamErrors[team.id] = self.message(error)
                    self.teamPayloads[team.id] = TeamVaultPayload(hosts: [], groups: [])
                    self.loadingTeamIDs.remove(team.id)
                }
            }
        }
    }

    func hosts(for teamID: String) -> [SavedHost] { teamPayloads[teamID]?.hosts ?? [] }
    func groups(for teamID: String) -> [HostGroup] { teamPayloads[teamID]?.groups ?? [] }

    // MARK: Files

    func ensureFilesLoaded(for team: TeamSummary) {
        guard filesByTeam[team.id] == nil else { return }
        Task {
            do {
                let files = try await self.client.listFiles(for: team)
                await MainActor.run { self.filesByTeam[team.id] = files; self.fileErrors[team.id] = nil }
            } catch {
                await MainActor.run { self.filesByTeam[team.id] = []; self.fileErrors[team.id] = self.message(error) }
            }
        }
    }

    /// Decrypt a shared file and write it to ~/Downloads. Returns nothing; sets
    /// `statusMessage`/`errorMessage`.
    func downloadFile(_ file: TeamFileMeta, from team: TeamSummary) {
        run("Downloading \(file.name)…") {
            let key = try await self.dek(for: team)
            let dl = try await self.client.downloadFile(for: team, fileID: file.id)
            guard let data = Data(base64Encoded: dl.ciphertext) else { throw VaultError("Corrupt file data") }
            let plaintext = try VaultCrypto.openBlob(data, dek: key)
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent(file.name)
            try plaintext.write(to: url)
            await MainActor.run { self.statusMessage = "Saved to \(url.path)" }
        }
    }

    // MARK: Host connect (auto-connect, like the Hosts tab)

    func connect(to host: SavedHost) {
        HostConnect.run(command: host.sshCommand(staged: true), name: host.label, host: host, staged: true)
    }

    // MARK: Debug seeding

    #if DEBUG
    func initializeVaultWithSampleData(_ team: TeamSummary) {
        run("Initializing \(team.name) vault…") {
            let priv = try self.activePrivateKey()
            guard let uid = self.activeAccountID else { throw VaultError("Sign in again") }
            let dek = VaultCrypto.generateDEK()
            let wrapped = try VaultCrypto.wrapDEK(dek, toPublicKeyBase64: VaultCrypto.publicKeyBase64(priv))
            try await self.client.putWrappedKeys(for: team, dekVersion: team.dekVersion,
                                                 keys: [WrappedKeyEntry(userId: uid, wrappedKey: wrapped)])
            await MainActor.run { self.dekCache[team.id] = dek }

            let sample = Self.samplePayloadJSON(teamName: team.name)
            let sealed = try VaultCrypto.sealBlob(sample, dek: dek)
            let current = try await self.client.vaultBlob(for: team)
            _ = try await self.client.putVaultBlob(for: team, ciphertextBase64: sealed.base64EncodedString(), baseVersion: current.version)

            // Also seed a sample shared file.
            let fileBytes = Data("# \(team.name) deploy key (sample)\nthis-is-not-a-real-key\n".utf8)
            let sealedFile = try VaultCrypto.sealBlob(fileBytes, dek: dek)
            try await self.client.uploadFile(for: team, name: "\(team.name)-deploy.key", contentType: "text/plain",
                                             dekVersion: team.dekVersion, ciphertextBase64: sealedFile.base64EncodedString())

            await MainActor.run {
                self.teamPayloads[team.id] = nil
                self.filesByTeam[team.id] = nil
                self.ensureHostsLoaded(for: team)
                self.ensureFilesLoaded(for: team)
            }
        }
    }

    private static func samplePayloadJSON(teamName: String) -> Data {
        let json = """
        {"hosts":[
          {"id":"\(UUID().uuidString)","label":"\(teamName) Web","hostname":"10.0.0.10","port":22,"username":"deploy"},
          {"id":"\(UUID().uuidString)","label":"\(teamName) DB","hostname":"10.0.0.20","port":22,"username":"postgres"}
        ],"groups":[]}
        """
        return Data(json.utf8)
    }
    #endif

    // MARK: Helpers

    private func message(_ error: Error) -> String {
        (error as? VaultError)?.message ?? error.localizedDescription
    }

    private func run(_ status: String, _ body: @escaping () async throws -> Void) {
        isBusy = true
        statusMessage = status
        errorMessage = nil
        Task {
            do { try await body() }
            catch { await MainActor.run { self.errorMessage = self.message(error) } }
            await MainActor.run { self.isBusy = false }
        }
    }
}
