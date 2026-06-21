import SwiftUI
import AppKit

/// Vaults tab: left sidebar with sub-sections + a content area on the right.
///
/// Sub-sections (Termius parity):
/// - **Hosts** — saved SSH/Mosh/Telnet/Serial connections (this is the
///   primary v1 surface we're building out)
/// - Keychain — credentials (later)
/// - Port Forwarding — saved tunnel rules (later)
/// - Snippets — shell-script library (later)
/// - Known Hosts — `~/.ssh/known_hosts` browser (later)
/// - Logs — session logs (later)
struct VaultsView: View {
    enum Section: Hashable, CaseIterable, Identifiable {
        case hosts, keychain, portForwarding, snippets, knownHosts, logs
        var id: Self { self }
        var label: String {
            switch self {
            case .hosts: return "Hosts"
            case .keychain: return "Keychain"
            case .portForwarding: return "Port Forwarding"
            case .snippets: return "Snippets"
            case .knownHosts: return "Known Hosts"
            case .logs: return "Logs"
            }
        }
        var icon: String {
            switch self {
            case .hosts: return "server.rack"
            case .keychain: return "key"
            case .portForwarding: return "arrow.triangle.swap"
            case .snippets: return "curlybraces"
            case .knownHosts: return "checkmark.shield"
            case .logs: return "clock"
            }
        }
    }

    @State private var selection: Section = .hosts

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color.black.opacity(0.18))
            Divider()
            Group {
                switch selection {
                case .hosts:          HostsSectionView()
                case .keychain:       keychainScaffold
                case .portForwarding: portForwardingScaffold
                case .snippets:       snippetsScaffold
                case .knownHosts:     KnownHostsSectionView()
                case .logs:           LogsSectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { sec in
                sidebarRow(sec)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private func sidebarRow(_ sec: Section) -> some View {
        let isSelected = selection == sec
        return Button {
            selection = sec
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sec.icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                Text(sec.label)
                Spacer()
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section scaffolds (shared top bar + empty state)
    //
    // These features aren't built yet, but they already share the reusable
    // `VaultsToolbar` so the top bar is identical to Hosts — only the buttons
    // differ. Buttons are disabled ("Coming soon") until each feature lands.

    private static let soon = "Coming soon"

    /// Trailing search / grid / list icons present on every section's top bar.
    private var trailingIcons: [VaultsToolbar.Item] {
        [
            .init(icon: "magnifyingglass", disabled: true, help: Self.soon),
            .init(icon: "square.grid.2x2", disabled: true, help: Self.soon),
            .init(icon: "list.bullet", disabled: true, help: Self.soon),
        ]
    }

    private var keychainScaffold: some View {
        VaultsScaffoldSection(
            toolbar: VaultsToolbar(
                primary: .init(title: "New key", icon: "plus", disabled: true, help: Self.soon),
                actions: [
                    .init(title: "Certificate", icon: "doc.text", disabled: true, help: Self.soon),
                    .init(title: "Touch ID", icon: "touchid", disabled: true, help: Self.soon),
                    .init(title: "FIDO2", icon: "key.radiowaves.forward", disabled: true, help: Self.soon),
                ],
                trailing: trailingIcons),
            empty: .init(icon: "key", title: "Add credentials",
                         subtitle: "Store SSH keys and credentials to connect to your servers quickly and securely.",
                         badge: Self.soon))
    }

    private var portForwardingScaffold: some View {
        VaultsScaffoldSection(
            toolbar: VaultsToolbar(
                primary: .init(title: "New forwarding", icon: "plus", disabled: true, help: Self.soon),
                trailing: trailingIcons),
            empty: .init(icon: "arrow.left.arrow.right", title: "Set up port forwarding",
                         subtitle: "Save port forwarding rules to reach databases, web apps, and other services.",
                         badge: Self.soon))
    }

    private var snippetsScaffold: some View {
        VaultsScaffoldSection(
            toolbar: VaultsToolbar(
                primary: .init(title: "New snippet", icon: "plus", disabled: true, help: Self.soon),
                actions: [.init(title: "Shell History", icon: "clock", disabled: true, help: Self.soon)],
                trailing: trailingIcons),
            empty: .init(icon: "curlybraces", title: "Create snippet",
                         subtitle: "Save your most-used commands as snippets to run them in one click.",
                         badge: Self.soon))
    }

}
