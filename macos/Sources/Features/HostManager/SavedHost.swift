import Foundation

/// A user-saved SSH connection. Persisted as JSON to
/// `~/.config/sarvterminal/hosts.json`.
///
/// Schema is intentionally generous so the editor can grow without
/// breaking existing files — every field has a safe default and
/// `Codable` decodes missing fields by using those defaults
/// (see the custom `init(from:)` below).
struct SavedHost: Codable, Identifiable, Hashable {
    var id: UUID

    // MARK: Identity
    var label: String          // display name shown in lists
    var hostname: String       // IP or DNS
    var port: Int              // 22 by default
    var username: String       // empty = let SSH default to current user
    var note: String           // free-form description

    // MARK: Authentication
    var authMethod: AuthMethod
    var identityFile: String   // absolute path; "" disables
    /// Stored as plaintext in the JSON file for now. UI surfaces a
    /// security note. Keychain integration is a follow-up.
    var password: String
    var forwardAgent: Bool

    // MARK: Connection options
    var strictHostKeyChecking: HostKeyChecking
    var connectTimeoutSeconds: Int          // 0 = use OS default
    var serverAliveIntervalSeconds: Int     // 0 = disabled
    var useCompression: Bool
    var requestTTY: Bool
    var proxyJump: String                   // "" = none

    // MARK: Port forwarding (raw ssh -L/-R/-D operands)
    var localForwards: [String]   // each like "8080:localhost:80"
    var remoteForwards: [String]  // each like "9000:localhost:9000"
    var dynamicForwardPort: Int   // 0 = disabled

    // MARK: Startup
    var initialCommand: String     // run after login; multiline ok

    // MARK: Organization
    /// First-class group reference (nil = root / no group).
    var groupID: UUID?
    /// Legacy free-form group string. Kept for migration from old JSON
    /// files; new code should use `groupID` exclusively.
    var group: String
    var tags: [String]

    // MARK: Appearance
    /// Ghostty theme name to apply on the new tab (empty = inherit global).
    /// Looked up against the same theme directories as Settings → Appearance.
    var themeName: String

    // MARK: OS / platform icon
    /// Manual OS choice (raw `HostPlatform`; "auto" = follow detection).
    var platform: String = HostPlatform.auto.rawValue
    /// Last auto-detected platform (raw `HostPlatform`; "" = never detected).
    var detectedPlatform: String = ""

    // MARK: Metadata
    var createdAt: Date
    var updatedAt: Date

    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        // Order = display order in pickers. Password is the most common
        // first-time setup, so it goes first.
        case password  = "password"
        case publicKey = "publicKey"
        case agent     = "agent"
        case ask       = "ask"
        var id: String { rawValue }

        var display: String {
            switch self {
            case .password:  return "Password"
            case .publicKey: return "Public key"
            case .agent:     return "SSH agent"
            case .ask:       return "Ask"
            }
        }
    }

    enum HostKeyChecking: String, Codable, CaseIterable, Identifiable {
        case yes
        case no
        case ask
        case acceptNew = "accept-new"
        var id: String { rawValue }

        var display: String {
            switch self {
            case .yes:       return "Strict (yes)"
            case .no:        return "Off (no)"
            case .ask:       return "Ask"
            case .acceptNew: return "Accept new"
            }
        }
    }

    // MARK: - Factory

    static func blank(hostname seed: String = "") -> SavedHost {
        let now = Date()
        return SavedHost(
            id: UUID(),
            label: seed.isEmpty ? "" : seed,
            hostname: seed,
            port: 22,
            username: "",
            note: "",
            authMethod: .password,
            identityFile: "",
            password: "",
            forwardAgent: false,
            strictHostKeyChecking: .ask,
            connectTimeoutSeconds: 0,
            serverAliveIntervalSeconds: 0,
            useCompression: false,
            requestTTY: false,
            proxyJump: "",
            localForwards: [],
            remoteForwards: [],
            dynamicForwardPort: 0,
            initialCommand: "",
            groupID: nil,
            group: "",
            tags: [],
            themeName: "",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Display helpers

    /// "deploy@10.0.1.10:2222" or "10.0.1.10" depending on what's set.
    var subtitle: String {
        var parts: [String] = []
        let host = hostname.isEmpty ? label : hostname
        if !username.isEmpty {
            parts.append("\(username)@\(host)")
        } else {
            parts.append(host)
        }
        if port != 22 { parts.append("port \(port)") }
        return parts.joined(separator: " · ")
    }

    /// Builds the shell command we run when the user opens a session.
    /// All knobs become explicit `-o Key=Value` so the host doesn't
    /// have to be present in `~/.ssh/config`.
    var sshCommand: String { sshCommand(staged: false) }

    /// Build the `ssh …` command line. When `staged` is true (the guided
    /// connection popup), add `NumberOfPasswordPrompts=1` so a wrong password
    /// makes ssh exit immediately — giving the popup a clean failure + Reconnect
    /// instead of leaving ssh re-prompting in the background.
    func sshCommand(staged: Bool = false) -> String {
        var args: [String] = ["ssh"]
        if port != 22 { args.append("-p \(port)") }
        if !identityFile.isEmpty {
            args.append("-i \(shellQuote(expandTilde(identityFile)))")
            args.append("-o IdentitiesOnly=yes")
        }
        if forwardAgent { args.append("-A") }
        if useCompression { args.append("-C") }
        if requestTTY { args.append("-t") }
        if !proxyJump.isEmpty { args.append("-J \(shellQuote(proxyJump))") }
        if connectTimeoutSeconds > 0 {
            args.append("-o ConnectTimeout=\(connectTimeoutSeconds)")
        }
        if serverAliveIntervalSeconds > 0 {
            args.append("-o ServerAliveInterval=\(serverAliveIntervalSeconds)")
            args.append("-o ServerAliveCountMax=3")
        } else if staged {
            // No explicit keepalive configured: for a staged (popup) connect add
            // a default so a session killed by sleep / network loss is DETECTED
            // (ssh exits within ~ServerAliveInterval × ServerAliveCountMax) and
            // the popup can auto-reconnect, instead of hanging on a dead socket.
            args.append("-o ServerAliveInterval=15")
            args.append("-o ServerAliveCountMax=3")
        }
        // For a staged (popup) connect we use `accept-new`: the GUI host-key
        // trust prompt is handled PRE-FLIGHT (via ssh-keyscan) before this ssh
        // runs, because `SSH_ASKPASS_REQUIRE=force` would otherwise route ssh's
        // interactive host-key question to the password helper and deadlock.
        let hostKeyChecking = staged ? "accept-new" : strictHostKeyChecking.rawValue
        args.append("-o StrictHostKeyChecking=\(hostKeyChecking)")
        if staged { args.append("-o NumberOfPasswordPrompts=1") }
        for f in localForwards   where !f.isEmpty { args.append("-L \(shellQuote(f))") }
        for f in remoteForwards  where !f.isEmpty { args.append("-R \(shellQuote(f))") }
        if dynamicForwardPort > 0 { args.append("-D \(dynamicForwardPort)") }

        let target = username.isEmpty ? hostname : "\(username)@\(hostname)"
        args.append(target)

        // Initial command: if multiline, pass as a single `-- bash -lc '...'`
        // style remote command. ssh joins remaining args with spaces, so we
        // shell-quote the whole script.
        let trimmedCmd = initialCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCmd.isEmpty {
            args.append(shellQuote(trimmedCmd))
        }
        return args.joined(separator: " ")
    }

    // MARK: - Codable (default-tolerant)

    /// Manual decoder so adding new fields later doesn't break old files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let blank = SavedHost.blank()
        id                          = try c.decodeIfPresent(UUID.self,           forKey: .id)                          ?? UUID()
        label                       = try c.decodeIfPresent(String.self,         forKey: .label)                       ?? ""
        hostname                    = try c.decodeIfPresent(String.self,         forKey: .hostname)                    ?? ""
        port                        = try c.decodeIfPresent(Int.self,            forKey: .port)                        ?? 22
        username                    = try c.decodeIfPresent(String.self,         forKey: .username)                    ?? ""
        note                        = try c.decodeIfPresent(String.self,         forKey: .note)                        ?? ""
        authMethod                  = try c.decodeIfPresent(AuthMethod.self,     forKey: .authMethod)                  ?? .password
        identityFile                = try c.decodeIfPresent(String.self,         forKey: .identityFile)                ?? ""
        password                    = try c.decodeIfPresent(String.self,         forKey: .password)                    ?? ""
        forwardAgent                = try c.decodeIfPresent(Bool.self,           forKey: .forwardAgent)                ?? false
        strictHostKeyChecking       = try c.decodeIfPresent(HostKeyChecking.self,forKey: .strictHostKeyChecking)       ?? .ask
        connectTimeoutSeconds       = try c.decodeIfPresent(Int.self,            forKey: .connectTimeoutSeconds)       ?? 0
        serverAliveIntervalSeconds  = try c.decodeIfPresent(Int.self,            forKey: .serverAliveIntervalSeconds)  ?? 0
        useCompression              = try c.decodeIfPresent(Bool.self,           forKey: .useCompression)              ?? false
        requestTTY                  = try c.decodeIfPresent(Bool.self,           forKey: .requestTTY)                  ?? false
        proxyJump                   = try c.decodeIfPresent(String.self,         forKey: .proxyJump)                   ?? ""
        localForwards               = try c.decodeIfPresent([String].self,       forKey: .localForwards)               ?? []
        remoteForwards              = try c.decodeIfPresent([String].self,       forKey: .remoteForwards)              ?? []
        dynamicForwardPort          = try c.decodeIfPresent(Int.self,            forKey: .dynamicForwardPort)          ?? 0
        initialCommand              = try c.decodeIfPresent(String.self,         forKey: .initialCommand)              ?? ""
        groupID                     = try c.decodeIfPresent(UUID.self,           forKey: .groupID)
        group                       = try c.decodeIfPresent(String.self,         forKey: .group)                       ?? ""
        tags                        = try c.decodeIfPresent([String].self,       forKey: .tags)                        ?? []
        themeName                   = try c.decodeIfPresent(String.self,         forKey: .themeName)                   ?? ""
        platform                    = try c.decodeIfPresent(String.self,         forKey: .platform)                    ?? HostPlatform.auto.rawValue
        detectedPlatform            = try c.decodeIfPresent(String.self,         forKey: .detectedPlatform)            ?? ""
        createdAt                   = try c.decodeIfPresent(Date.self,           forKey: .createdAt)                   ?? blank.createdAt
        updatedAt                   = try c.decodeIfPresent(Date.self,           forKey: .updatedAt)                   ?? blank.updatedAt
    }

    init(
        id: UUID, label: String, hostname: String, port: Int, username: String,
        note: String, authMethod: AuthMethod, identityFile: String,
        password: String,
        forwardAgent: Bool, strictHostKeyChecking: HostKeyChecking,
        connectTimeoutSeconds: Int, serverAliveIntervalSeconds: Int,
        useCompression: Bool, requestTTY: Bool, proxyJump: String,
        localForwards: [String], remoteForwards: [String], dynamicForwardPort: Int,
        initialCommand: String, groupID: UUID?, group: String, tags: [String],
        themeName: String,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id; self.label = label; self.hostname = hostname
        self.port = port; self.username = username; self.note = note
        self.authMethod = authMethod; self.identityFile = identityFile
        self.password = password
        self.forwardAgent = forwardAgent
        self.strictHostKeyChecking = strictHostKeyChecking
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.serverAliveIntervalSeconds = serverAliveIntervalSeconds
        self.useCompression = useCompression; self.requestTTY = requestTTY
        self.proxyJump = proxyJump; self.localForwards = localForwards
        self.remoteForwards = remoteForwards
        self.dynamicForwardPort = dynamicForwardPort
        self.initialCommand = initialCommand
        self.groupID = groupID; self.group = group; self.tags = tags
        self.themeName = themeName
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - Validation

extension SavedHost {
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !hostname.isEmpty { return hostname }
        return "Untitled host"
    }

    /// True when the host has enough info to attempt a connect.
    var canConnect: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "Password" auth requires a stored password — it's mandatory, because the
    /// connection popup never prompts for a password method (it connects with the
    /// saved one). If you don't want to store a password, use "Ask" instead.
    var passwordRequirementMet: Bool {
        authMethod != .password || !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Enough info to save: connectable AND the password rule is satisfied.
    var canSave: Bool { canConnect && passwordRequirementMet }

    /// Equality ignoring the bookkeeping timestamps — "did the user actually
    /// change anything", used to skip no-op autosaves.
    func contentEquals(_ other: SavedHost) -> Bool {
        var a = self
        var b = other
        a.createdAt = .distantPast; b.createdAt = .distantPast
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        return a == b
    }
}

// MARK: - Helpers

/// Wrap in single quotes for safe shell embedding, escaping internal `'`.
private func shellQuote(_ s: String) -> String {
    if s.range(of: "[^A-Za-z0-9_@%+=:,./-]", options: .regularExpression) == nil {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Expand a leading `~` to the home directory.
private func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    let suffix = path.dropFirst()
    return NSHomeDirectory() + suffix
}
