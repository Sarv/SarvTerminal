import Foundation

/// A host parsed from an import source but NOT yet saved — shown in the preview
/// screen so the user can review/deselect before committing. `groupPath` is a
/// `/`-separated path resolved into the group tree only on commit.
struct ParsedHost: Identifiable {
    let id = UUID()
    var label: String
    var hostname: String
    var port: Int = 22
    var username: String = ""
    var auth: SavedHost.AuthMethod = .agent
    var identityFile: String = ""
    var password: String = ""
    var groupPath: String = ""
    var tags: [String] = []
    var note: String = ""

    var subtitle: String {
        var s = username.isEmpty ? hostname : "\(username)@\(hostname)"
        if port != 22 { s += ":\(port)" }
        if !groupPath.isEmpty { s += "  ·  \(groupPath)" }
        return s
    }

    func toSavedHost() -> SavedHost {
        var h = SavedHost.blank(hostname: hostname)
        h.label = label.isEmpty ? hostname : label
        h.username = username
        h.port = port
        h.authMethod = auth
        h.identityFile = identityFile
        h.password = password
        h.tags = tags
        h.note = note
        return h
    }
}

/// Outcome of committing a set of parsed hosts.
struct HostImportResult {
    var imported = 0
    var skipped = 0     // already-saved duplicates
    var note: String?

    var summary: String {
        if let note { return note }
        var parts = ["Imported \(imported) host\(imported == 1 ? "" : "s")"]
        if skipped > 0 { parts.append("\(skipped) already saved") }
        return parts.joined(separator: " · ")
    }
}

/// Parses external sources into `ParsedHost`s and commits the chosen ones into
/// `SavedHostsStore`, deduping by `hostname`+`username` and resolving group paths.
enum HostImporter {
    /// The single CSV layout we support — also what "Save template" writes.
    static let csvHeader = "label,hostname,port,username,auth,identity_file,password,group,tags,note"
    static let csvTemplate = """
    \(csvHeader)
    My Server,192.168.1.10,22,deploy,password,,s3cret,Workspace/Dev,prod;web,Primary app server
    Bastion,bastion.example.com,2222,ubuntu,publicKey,~/.ssh/id_ed25519,,Workspace,jump,Jump host
    Local VM,127.0.0.1,2200,vagrant,agent,,,,,
    """

    // MARK: - Parse (no side effects)

    static func parseSSHConfig() -> [ParsedHost] {
        SSHConfigDiscovery.loadAll().map {
            ParsedHost(label: $0.label,
                       hostname: $0.hostname ?? $0.label,
                       port: $0.port ?? 22,
                       username: $0.user ?? "")
        }
    }

    /// Returns the parsed hosts, or an error note describing why parsing failed.
    static func parseCSV(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        let rows = content.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = rows.first else { return ([], "The CSV file is empty.") }
        let headers = parseRow(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ name: String) -> Int? { headers.firstIndex(of: name) }
        guard let hostnameCol = col("hostname") else {
            return ([], "CSV needs a 'hostname' column. Use the template.")
        }
        let labelCol = col("label"), portCol = col("port"), userCol = col("username")
        let authCol = col("auth"), identityCol = col("identity_file"), passwordCol = col("password")
        let groupCol = col("group"), tagsCol = col("tags"), noteCol = col("note")

        var parsed: [ParsedHost] = []
        for line in rows.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = parseRow(line)
            func get(_ i: Int?) -> String {
                guard let i, i >= 0, i < f.count else { return "" }
                return f[i].trimmingCharacters(in: .whitespaces)
            }
            let hostname = get(hostnameCol)
            if hostname.isEmpty { continue }
            let label = get(labelCol)
            parsed.append(ParsedHost(
                label: label.isEmpty ? hostname : label,
                hostname: hostname,
                port: Int(get(portCol)) ?? 22,
                username: get(userCol),
                auth: parseAuth(get(authCol)),
                identityFile: get(identityCol),
                password: get(passwordCol),
                groupPath: get(groupCol),
                tags: get(tagsCol).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                note: get(noteCol)
            ))
        }
        if parsed.isEmpty { return ([], "No host rows found below the header.") }
        return (parsed, nil)
    }

    // MARK: - PuTTY (.reg export of HKCU\…\PuTTY\Sessions)

    static func parsePuTTY(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        var hosts: [ParsedHost] = []
        var name: String?
        var fields: [String: String] = [:]

        func flush() {
            defer { fields = [:]; name = nil }
            guard let name, !name.isEmpty, name.lowercased() != "default settings" else { return }
            let host = fields["hostname"] ?? ""
            let proto = (fields["protocol"] ?? "ssh").lowercased()
            guard !host.isEmpty, proto.isEmpty || proto == "ssh" else { return }
            hosts.append(ParsedHost(label: name, hostname: host,
                                    port: Int(fields["portnumber"] ?? "") ?? 22,
                                    username: fields["username"] ?? ""))
        }

        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if let r = line.range(of: "\\Sessions\\") {
                    var key = String(line[r.upperBound...])
                    if key.hasSuffix("]") { key = String(key.dropLast()) }
                    name = key.removingPercentEncoding ?? key
                }
            } else if name != nil, let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
                var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("dword:") {
                    val = String(Int(val.dropFirst(6), radix: 16) ?? 0)
                } else {
                    val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                fields[key] = val
            }
        }
        flush()
        return hosts.isEmpty ? ([], "No SSH sessions found in the PuTTY export (.reg).") : (hosts, nil)
    }

    // MARK: - MobaXterm (.mxtsessions)

    static func parseMobaXterm(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        var hosts: [ParsedHost] = []
        var groupPath = ""
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { groupPath = ""; continue }
            if line.hasPrefix("SubRep=") {
                groupPath = String(line.dropFirst("SubRep=".count)).replacingOccurrences(of: "\\", with: "/")
                continue
            }
            guard let eq = line.firstIndex(of: "="), line.contains("#109#") else { continue }  // 109 = SSH
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let parts = String(line[line.index(after: eq)...]).components(separatedBy: "%")
            // " #109#0" % host % port % user % …
            guard parts.count >= 2, !parts[1].isEmpty else { continue }
            hosts.append(ParsedHost(
                label: name.isEmpty ? parts[1] : name,
                hostname: parts[1],
                port: parts.count > 2 ? (Int(parts[2]) ?? 22) : 22,
                username: parts.count > 3 ? parts[3] : "",
                groupPath: groupPath))
        }
        return hosts.isEmpty ? ([], "No SSH sessions found in the MobaXterm file.") : (hosts, nil)
    }

    // MARK: - SecureCRT (Session .ini files / Sessions folder)

    static func parseSecureCRT(at url: URL) -> (hosts: [ParsedHost], error: String?) {
        let fm = FileManager.default
        var inis: [(url: URL, rel: String)] = []
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let basePrefix = url.path + "/"
            if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let file as URL in walker where file.pathExtension.lowercased() == "ini" {
                    let rel = file.deletingPathExtension().path.replacingOccurrences(of: basePrefix, with: "")
                    inis.append((file, rel))
                }
            }
        } else if url.pathExtension.lowercased() == "ini" {
            inis.append((url, url.deletingPathExtension().lastPathComponent))
        }

        var hosts: [ParsedHost] = []
        for item in inis {
            guard let content = try? String(contentsOf: item.url, encoding: .utf8),
                  let host = parseSecureCRTSession(content, relPath: item.rel) else { continue }
            hosts.append(host)
        }
        return hosts.isEmpty ? ([], "No SSH sessions found. Pick your SecureCRT 'Sessions' folder.") : (hosts, nil)
    }

    private static func parseSecureCRTSession(_ content: String, relPath: String) -> ParsedHost? {
        var hostname = "", username = "", proto = ""
        var port = 22
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lhs = String(line[..<eq])
            let rhs = String(line[line.index(after: eq)...])
            guard let q1 = lhs.firstIndex(of: "\""), let q2 = lhs.lastIndex(of: "\""), q1 < q2 else { continue }
            let key = String(lhs[lhs.index(after: q1)..<q2])
            switch key {
            case "Hostname":      hostname = rhs
            case "Username":      username = rhs
            case "Protocol Name": proto = rhs.lowercased()
            default:
                if key.contains("Port"), lhs.hasPrefix("D:") { port = Int(rhs, radix: 16) ?? 22 }
            }
        }
        guard !hostname.isEmpty else { return nil }
        if !proto.isEmpty, !proto.contains("ssh") { return nil }   // skip telnet/rlogin/serial
        let comps = relPath.split(separator: "/").map(String.init)
        return ParsedHost(label: comps.last ?? hostname,
                          hostname: hostname, port: port, username: username,
                          groupPath: comps.dropLast().joined(separator: "/"))
    }

    // MARK: - Commit (mutates the stores)

    @MainActor
    static func commit(_ hosts: [ParsedHost]) -> HostImportResult {
        var result = HostImportResult()
        var groupCache: [String: UUID] = [:]
        for p in hosts {
            if isDuplicate(hostname: p.hostname, username: p.username) { result.skipped += 1; continue }
            var host = p.toSavedHost()
            if !p.groupPath.isEmpty { host.groupID = resolveGroup(path: p.groupPath, cache: &groupCache) }
            SavedHostsStore.shared.upsert(host)
            result.imported += 1
        }
        return result
    }

    @MainActor
    static func isDuplicate(hostname: String, username: String) -> Bool {
        SavedHostsStore.shared.hosts.contains {
            $0.hostname.lowercased() == hostname.lowercased()
                && $0.username.lowercased() == username.lowercased()
        }
    }

    // MARK: - Helpers

    private static func parseAuth(_ raw: String) -> SavedHost.AuthMethod {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "password":         return .password
        case "publickey", "key": return .publicKey
        case "ask":              return .ask
        default:                 return .agent
        }
    }

    @MainActor
    private static func resolveGroup(path: String, cache: inout [String: UUID]) -> UUID? {
        if let cached = cache[path.lowercased()] { return cached }
        let parts = path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let store = HostGroupsStore.shared
        var parentID: UUID?
        for name in parts {
            if let existing = store.children(of: parentID).first(where: {
                $0.displayName.lowercased() == name.lowercased()
            }) {
                parentID = existing.id
            } else {
                var group = HostGroup.blank(parentID: parentID)
                group.name = name
                store.upsert(group)
                parentID = group.id
            }
        }
        cache[path.lowercased()] = parentID
        return parentID
    }

    /// Minimal RFC-4180-ish single-row CSV parser (quoted fields, `""` escapes).
    static func parseRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" { current.append("\""); i = next }
                    else { inQuotes = false }
                } else { current.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":  fields.append(current); current = ""
                default:   current.append(c)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }
}
