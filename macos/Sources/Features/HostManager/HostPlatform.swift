import SwiftUI
import AppKit

/// The operating system a saved host runs, shown as the host's icon (Termius
/// style). Chosen manually in the host editor, or auto-detected on the first
/// successful SSH connect (`HostPlatformDetector`); a manual choice always
/// wins over detection.
enum HostPlatform: String, CaseIterable, Identifiable {
    case auto        // follow auto-detection (default)
    case linux       // generic Tux
    case ubuntu, debian, fedora, redhat, centos, rocky, alma
    case arch, suse, alpine, raspberrypi
    case freebsd, macos, windows

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (detect)"
        case .linux: return "Linux (generic)"
        case .ubuntu: return "Ubuntu"
        case .debian: return "Debian"
        case .fedora: return "Fedora"
        case .redhat: return "Red Hat (RHEL)"
        case .centos: return "CentOS"
        case .rocky: return "Rocky Linux"
        case .alma: return "AlmaLinux"
        case .arch: return "Arch Linux"
        case .suse: return "openSUSE / SLES"
        case .alpine: return "Alpine"
        case .raspberrypi: return "Raspberry Pi"
        case .freebsd: return "FreeBSD"
        case .macos: return "macOS"
        case .windows: return "Windows"
        }
    }

    /// Bundled logo (Resources/OSIcons/os_*.svg, flattened to Resources root).
    /// nil for `.auto` (no logo of its own).
    var assetName: String? {
        switch self {
        case .auto: return nil
        case .linux: return "os_linux"
        case .ubuntu: return "os_ubuntu"
        case .debian: return "os_debian"
        case .fedora: return "os_fedora"
        case .redhat: return "os_redhat"
        case .centos: return "os_centos"
        case .rocky: return "os_rockylinux"
        case .alma: return "os_almalinux"
        case .arch: return "os_archlinux"
        case .suse: return "os_opensuse"
        case .alpine: return "os_alpinelinux"
        case .raspberrypi: return "os_raspberrypi"
        case .freebsd: return "os_freebsd"
        case .macos: return "os_apple"
        case .windows: return "os_windows"
        }
    }

    /// Map an `/etc/os-release` ID (or `uname -s` output) to a platform.
    static func from(osReleaseID id: String) -> HostPlatform? {
        switch id.lowercased() {
        case "ubuntu": return .ubuntu
        case "debian": return .debian
        case "fedora": return .fedora
        case "rhel": return .redhat
        case "centos": return .centos
        case "rocky": return .rocky
        case "almalinux": return .alma
        case "arch", "archarm", "manjaro": return .arch
        case let s where s.hasPrefix("opensuse") || s == "sles": return .suse
        case "alpine": return .alpine
        case "raspbian": return .raspberrypi
        case "freebsd": return .freebsd
        case "darwin": return .macos
        case "linux": return .linux
        default: return nil
        }
    }

    /// The platform to SHOW for a host: manual choice unless it's auto, then
    /// whatever detection stored, else nil (caller falls back to the generic
    /// server glyph).
    static func effective(for host: SavedHost) -> HostPlatform? {
        if let manual = HostPlatform(rawValue: host.platform), manual != .auto { return manual }
        if let detected = HostPlatform(rawValue: host.detectedPlatform), detected != .auto { return detected }
        return nil
    }

    // MARK: - Icon loading

    /// Template NSImage for the logo, cached. Tinted by SwiftUI foregroundStyle.
    private static var cache: [String: NSImage] = [:]
    var templateImage: NSImage? {
        guard let assetName else { return nil }
        if let hit = Self.cache[assetName] { return hit }
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        Self.cache[assetName] = img
        return img
    }
}

/// The 44×44 squircle icon for a host card/row: the OS logo when known,
/// otherwise the generic server glyph — ONE view used by grid card, list row
/// and pickers so the fallback logic never diverges.
struct HostOSIconView: View {
    let host: SavedHost
    var side: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: side, height: side)
            if let platform = HostPlatform.effective(for: host),
               let image = platform.templateImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.55, height: side * 0.55)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: side * 0.41, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// One-shot background OS probe after a successful connect. Never interactive:
/// key/agent hosts run with BatchMode; password hosts feed the stored password
/// through the same `SSHAskpass` helper the tunnels use. "Ask" hosts without a
/// stored password rely on the manual picker.
enum HostPlatformDetector {
    static func probeIfNeeded(_ host: SavedHost) {
        let manual = HostPlatform(rawValue: host.platform) ?? .auto
        guard manual == .auto, host.detectedPlatform.isEmpty else { return }
        guard !host.hostname.isEmpty else { return }
        let usesPassword = (host.authMethod == .password || host.authMethod == .ask)
        // Password auth without a stored password can't be probed silently.
        if usesPassword && host.password.isEmpty { return }

        DispatchQueue.global(qos: .utility).async {
            var args = ["-o", "ConnectTimeout=8",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-p", String(host.port)]
            if usesPassword {
                args += ["-o", "NumberOfPasswordPrompts=1"]
            } else {
                // Key/agent: BatchMode guarantees no prompt can ever appear.
                args += ["-o", "BatchMode=yes"]
                if host.authMethod == .publicKey, !host.identityFile.isEmpty {
                    args += ["-i", (host.identityFile as NSString).expandingTildeInPath]
                }
            }
            let target = host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"
            args.append(target)
            args.append("cat /etc/os-release 2>/dev/null || uname -s")

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = args
            // No controlling TTY → ssh routes the password through SSH_ASKPASS,
            // fed from the same helper the port-forward tunnels use.
            proc.standardInput = FileHandle.nullDevice
            var askpassFile: String?
            if usesPassword {
                let env = SSHAskpass.env(forPassword: host.password)
                guard !env.isEmpty else { return }
                askpassFile = env["SARV_ASKPASS_FILE"]
                proc.environment = ProcessInfo.processInfo.environment
                    .merging(env) { _, new in new }
            }
            defer {
                if let askpassFile { try? FileManager.default.removeItem(atPath: askpassFile) }
            }
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let data = try? out.fileHandleForReading.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return }

            guard let platform = parse(text) else { return }
            DispatchQueue.main.async {
                guard var fresh = SavedHostsStore.shared.host(withID: host.id) else { return }
                fresh.detectedPlatform = platform.rawValue
                SavedHostsStore.shared.upsert(fresh)
            }
        }
    }

    /// Parse `/etc/os-release` content (ID= line) or a bare `uname -s` output.
    static func parse(_ text: String) -> HostPlatform? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ID=") else { continue }
            let id = line.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return HostPlatform.from(osReleaseID: id)
        }
        // No os-release → single-line uname output (FreeBSD, Darwin, Linux).
        let first = text.components(separatedBy: .newlines)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        return HostPlatform.from(osReleaseID: first)
    }
}
