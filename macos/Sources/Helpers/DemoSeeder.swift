#if DEBUG
import Foundation

/// Populates the isolated demo workspace (`~/.config/sarvterminal-demo` +
/// its own `.ssh`) with realistic, privacy-safe sample data so the README
/// screenshots can be captured from a full-looking app.
///
/// Only runs in `--demo` mode (see `scripts/demo.sh`) and only once — a marker
/// file guards against re-seeding. All hostnames/IPs use reserved documentation
/// ranges (RFC 5737 TEST-NET, RFC 1918 private) so nothing points anywhere real.
enum DemoSeeder {
    @MainActor
    static func seedIfNeeded() {
        guard AppPaths.isDemo else { return }
        let marker = AppPaths.configDir.appendingPathComponent(".demo-seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Write the marker up front so a crash mid-seed can't cause a double run.
        FileManager.default.createFile(atPath: marker.path, contents: Data())

        // SSH keys + known_hosts are file/Process work — do them off the main
        // thread, then hop back to seed the (main-only) ObservableObject stores.
        DispatchQueue.global(qos: .userInitiated).async {
            seedSSHKeys()
            seedKnownHostsFile()
            DispatchQueue.main.async {
                seedStores()
                KnownHostsStore.shared.reload()
                Task { await SSHKeyManager.shared.refresh() }
            }
        }
    }

    // MARK: - SSH keys (Keychain screen)

    /// Generate a few sample key pairs (one of each type) in the demo `.ssh`.
    private static func seedSSHKeys() {
        let dir = AppPaths.sshDir
        let specs: [(name: String, args: [String], comment: String)] = [
            ("id_ed25519",   ["-t", "ed25519"],            "sarv@macbook-pro"),
            ("deploy_rsa",   ["-t", "rsa", "-b", "4096"],  "deploy@ci-server"),
            ("backup_ecdsa", ["-t", "ecdsa", "-b", "521"], "backup@nas"),
        ]
        for spec in specs {
            let path = dir.appendingPathComponent(spec.name).path
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            _ = run("/usr/bin/ssh-keygen", spec.args + ["-f", path, "-N", "", "-C", spec.comment, "-q"])
        }
    }

    // MARK: - Known hosts screen

    /// Build a `known_hosts` from the just-generated public keys (valid base64 →
    /// real fingerprints) mapped onto sample host addresses.
    private static func seedKnownHostsFile() {
        let dir = AppPaths.sshDir
        let pubs = ["id_ed25519.pub", "deploy_rsa.pub", "backup_ecdsa.pub"].compactMap { name -> String? in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
            let toks = text.split(separator: " ")
            guard toks.count >= 2 else { return nil }
            return "\(toks[0]) \(toks[1])"   // "<keytype> <base64blob>"
        }
        guard !pubs.isEmpty else { return }
        let hosts = ["203.0.113.10", "[127.0.0.1]:2222", "10.0.5.20", "github.com", "198.51.100.5"]
        let lines = hosts.enumerated().map { "\($1) \(pubs[$0 % pubs.count])" }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    }

    // MARK: - Encrypted stores (hosts, groups, port-forwards, snippets, logs)

    @MainActor
    private static func seedStores() {
        let groupsStore = HostGroupsStore.shared
        let hostsStore = SavedHostsStore.shared
        let forwards = PortForwardStore.shared
        let snippets = SnippetsStore.shared
        let activity = ActivityLog.shared

        // Groups: a workspace → project tree.
        func makeGroup(_ name: String, parent: UUID?, icon: String, color: String) -> UUID {
            var g = HostGroup.blank(parentID: parent)
            g.name = name; g.iconSystemName = icon; g.colorHex = color
            groupsStore.upsert(g)
            return g.id
        }
        let prod = makeGroup("Production", parent: nil, icon: "server.rack", color: "#FF453A")
        let web = makeGroup("Web", parent: prod, icon: "globe", color: "#0A84FF")
        let dbs = makeGroup("Databases", parent: prod, icon: "cylinder.split.1x2", color: "#30D158")
        let staging = makeGroup("Staging", parent: nil, icon: "hammer", color: "#FF9F0A")
        let personal = makeGroup("Personal", parent: nil, icon: "house", color: "#BF5AF2")

        // Hosts.
        @discardableResult
        func makeHost(_ label: String, _ hostname: String, port: Int = 22, user: String,
                      group: UUID?, tags: [String], auth: SavedHost.AuthMethod = .agent,
                      identity: String = "", note: String = "") -> UUID {
            var h = SavedHost.blank(hostname: hostname)
            h.label = label; h.username = user; h.port = port
            h.groupID = group; h.tags = tags; h.authMethod = auth
            h.identityFile = identity; h.note = note
            hostsStore.upsert(h)
            return h.id
        }
        let edKey = AppPaths.sshDir.appendingPathComponent("id_ed25519").path
        makeHost("web-prod-01", "203.0.113.10", user: "deploy", group: web,
                 tags: ["nginx", "prod"], note: "Primary web node")
        makeHost("web-prod-02", "203.0.113.11", user: "deploy", group: web,
                 tags: ["nginx", "prod"])
        let dbID = makeHost("db-primary", "10.0.5.20", user: "postgres", group: dbs,
                            tags: ["postgres", "prod"], auth: .publicKey, identity: edKey,
                            note: "Main PostgreSQL cluster")
        let redisID = makeHost("cache-redis", "10.0.5.30", user: "redis", group: dbs,
                               tags: ["redis"])
        let bastionID = makeHost("bastion", "203.0.113.1", user: "admin", group: prod,
                                 tags: ["jump"], note: "Jump host for the prod VPC")
        let stagingID = makeHost("staging-app", "198.51.100.5", user: "ubuntu", group: staging,
                                 tags: ["staging", "app"])
        makeHost("raspberry-pi", "192.168.1.50", user: "pi", group: personal, tags: ["iot"])
        makeHost("localhost", "127.0.0.1", user: NSUserName(), group: personal,
                 tags: ["local"], note: "This Mac (enable Remote Login for SSH/SFTP)")
        makeHost("backup-nas", "192.168.1.100", user: "backup", group: personal,
                 tags: ["storage"], auth: .password)

        // Port forwards (reference the hosts above).
        func makeForward(_ name: String, _ kind: PortForward.Kind, host: UUID,
                         listen: Int, dest: String = "localhost", destPort: Int = 0) {
            var f = PortForward.blank()
            f.name = name; f.kind = kind; f.hostID = host
            f.listenPort = listen; f.destinationHost = dest
            f.destinationPort = destPort == 0 ? listen : destPort
            forwards.upsert(f)
        }
        makeForward("Postgres tunnel", .local, host: dbID, listen: 5432)
        makeForward("Redis tunnel", .local, host: redisID, listen: 6379)
        makeForward("SOCKS proxy", .dynamic, host: bastionID, listen: 1080)
        makeForward("Webhook relay", .remote, host: stagingID, listen: 9000, destPort: 3000)

        // Snippets.
        let snips: [(String, String)] = [
            ("Tail nginx errors", "tail -f /var/log/nginx/error.log"),
            ("Disk usage", "df -h && du -sh ./*"),
            ("Docker containers", "docker ps -a"),
            ("System update", "sudo apt update && sudo apt upgrade -y"),
            ("Restart nginx", "sudo systemctl restart nginx"),
            ("Listening ports", "sudo lsof -iTCP -sTCP:LISTEN -n -P"),
            ("Deploy & restart", "git pull && npm ci && pm2 restart all"),
        ]
        for (name, cmd) in snips {
            snippets.upsert(Snippet(id: UUID(), name: name, command: cmd,
                                    createdAt: Date(), updatedAt: Date()))
        }

        // Activity log — logged oldest-first so the newest sits on top.
        activity.log(.info, "Demo workspace loaded")
        activity.log(.connection, "Connected to web-prod-01", detail: "203.0.113.10:22")
        activity.log(.transfer, "Uploaded release.tar.gz", detail: "web-prod-01:/var/www — 12.4 MB")
        activity.log(.sync, "Settings synced", detail: "GitHub · 4 files")
        activity.log(.connection, "Connection failed: db-primary", detail: "Operation timed out", success: false)
        activity.log(.transfer, "Downloaded backup.sql", detail: "db-primary:/backups — 88 MB")
        activity.log(.info, "Started SOCKS proxy", detail: "127.0.0.1:1080 via bastion")
        activity.log(.error, "Port forward failed", detail: "bind: address already in use", success: false)
        activity.log(.connection, "Serial console opened", detail: "/dev/cu.usbserial-1420 @ 115200")
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
#endif
