import Foundation
import Combine

/// A saved SSH port-forwarding (tunnel) rule. Persisted as JSON to
/// `~/.config/sarvterminal/portforwards.json`.
struct PortForward: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: Kind
    /// The saved host we tunnel THROUGH (its credentials/options are reused).
    var hostID: UUID
    var bindAddress: String     // local listen address, default 127.0.0.1
    var listenPort: Int         // the port opened on the bind side
    var destinationHost: String // target host (as seen from the far end); unused for dynamic
    var destinationPort: Int    // target port; unused for dynamic
    var createdAt: Date
    var updatedAt: Date

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case local   // -L  listen locally → forward to destination via the server
        case remote  // -R  listen on the server → forward back to destination here
        case dynamic // -D  local SOCKS proxy
        var id: String { rawValue }

        var display: String {
            switch self {
            case .local:   return "Local (-L)"
            case .remote:  return "Remote (-R)"
            case .dynamic: return "Dynamic / SOCKS (-D)"
            }
        }

        var short: String {
            switch self {
            case .local:   return "Local"
            case .remote:  return "Remote"
            case .dynamic: return "SOCKS"
            }
        }

        var needsDestination: Bool { self != .dynamic }
    }

    static func blank() -> PortForward {
        let now = Date()
        return PortForward(
            id: UUID(), name: "", kind: .local, hostID: UUID(),
            bindAddress: "127.0.0.1", listenPort: 8080,
            destinationHost: "localhost", destinationPort: 80,
            createdAt: now, updatedAt: now)
    }

    /// Custom decoder so older/partial JSON still loads with safe defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id              = try c.decodeIfPresent(UUID.self,   forKey: .id)              ?? UUID()
        name            = try c.decodeIfPresent(String.self, forKey: .name)            ?? ""
        kind            = try c.decodeIfPresent(Kind.self,   forKey: .kind)            ?? .local
        hostID          = try c.decodeIfPresent(UUID.self,   forKey: .hostID)          ?? UUID()
        bindAddress     = try c.decodeIfPresent(String.self, forKey: .bindAddress)     ?? "127.0.0.1"
        listenPort      = try c.decodeIfPresent(Int.self,    forKey: .listenPort)      ?? 8080
        destinationHost = try c.decodeIfPresent(String.self, forKey: .destinationHost) ?? "localhost"
        destinationPort = try c.decodeIfPresent(Int.self,    forKey: .destinationPort) ?? 80
        createdAt       = try c.decodeIfPresent(Date.self,   forKey: .createdAt)       ?? now
        updatedAt       = try c.decodeIfPresent(Date.self,   forKey: .updatedAt)       ?? now
    }

    init(id: UUID, name: String, kind: Kind, hostID: UUID, bindAddress: String,
         listenPort: Int, destinationHost: String, destinationPort: Int,
         createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.kind = kind; self.hostID = hostID
        self.bindAddress = bindAddress; self.listenPort = listenPort
        self.destinationHost = destinationHost; self.destinationPort = destinationPort
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled tunnel" : trimmed
    }

    /// Human-readable route, e.g. "127.0.0.1:8080 → db.internal:5432".
    var route: String {
        switch kind {
        case .local:   return "\(bindAddress):\(listenPort) → \(destinationHost):\(destinationPort)"
        case .remote:  return "server:\(listenPort) → \(destinationHost):\(destinationPort)"
        case .dynamic: return "SOCKS proxy on \(bindAddress):\(listenPort)"
        }
    }
}

/// Owns the persisted port-forward rules. Storage:
/// `~/.config/sarvterminal/portforwards.json`. Mirrors `SnippetsStore`.
final class PortForwardStore: ObservableObject {
    static let shared = PortForwardStore()

    @Published private(set) var forwards: [PortForward] = []
    private(set) var loadFailed = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "PortForwardStore.io", qos: .utility)

    private init() {
        let dir = AppPaths.configDir
        fileURL = dir.appendingPathComponent("portforwards.json")
        load()
    }

    // MARK: - CRUD

    func upsert(_ forward: PortForward) {
        var updated = forward
        updated.updatedAt = Date()
        if let idx = forwards.firstIndex(where: { $0.id == forward.id }) {
            forwards[idx] = updated
        } else {
            forwards.append(updated)
        }
        sortInPlace()
        persist()
    }

    func delete(_ forward: PortForward) {
        forwards.removeAll { $0.id == forward.id }
        persist()
    }

    // MARK: - Sync helpers

    func ingest(_ incoming: [PortForward]) {
        var changed = false
        for f in incoming {
            if let idx = forwards.firstIndex(where: { $0.id == f.id }) {
                if f.updatedAt >= forwards[idx].updatedAt { forwards[idx] = f; changed = true }
            } else {
                forwards.append(f); changed = true
            }
        }
        if changed { sortInPlace(); persist() }
    }

    func replaceAll(_ incoming: [PortForward]) {
        forwards = incoming
        sortInPlace()
        persist()
    }

    // MARK: - IO

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loadFailed = false; return }
        guard let data = try? Data(contentsOf: fileURL) else { loadFailed = true; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([PortForward].self, from: data) {
            forwards = decoded
            sortInPlace()
            loadFailed = false
        } else {
            loadFailed = true
        }
    }

    private func persist() {
        let snapshot = forwards
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func sortInPlace() {
        forwards.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
