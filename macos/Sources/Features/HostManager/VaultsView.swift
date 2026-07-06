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
        case hosts, savedSessions, teams, keychain, portForwarding, snippets, knownHosts, logs
        var id: Self { self }
        var label: String {
            switch self {
            case .hosts: return "Hosts"
            case .savedSessions: return "Saved Sessions"
            case .teams: return "Teams"
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
            case .savedSessions: return "rectangle.split.2x2"
            case .teams: return "person.2"
            case .keychain: return "key"
            case .portForwarding: return "arrow.triangle.swap"
            case .snippets: return "curlybraces"
            case .knownHosts: return "checkmark.shield"
            case .logs: return "clock"
            }
        }
    }

    @ObservedObject private var sel = HostManagerSelection.shared
    /// Sidebar row currently under the pointer (hover highlight).
    @State private var hoveredSection: Section?
    private var selection: Section {
        get { sel.vaultsSection }
        nonmutating set { sel.vaultsSection = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                // Just wide enough that "Port Forwarding" / "Saved Sessions"
                // stay on one line even in the selected (semibold) weight.
                .frame(width: 180)
                .background(Color.black.opacity(0.18))
            Divider()
            Group {
                switch selection {
                case .hosts:          HostsSectionView()
                case .savedSessions:  SavedSessionsSectionView()
                case .teams:          TeamsSectionView()
                case .keychain:       KeychainSectionView()
                case .portForwarding: PortForwardingSectionView()
                case .snippets:       SnippetsSectionView()
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
        let isHovered = hoveredSection == sec
        return Button {
            selection = sec
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sec.icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
                Text(sec.label)
                    // Always render the full label — never truncate, never wrap
                    // (the sidebar width is tuned around the longest label).
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor
                          : isHovered ? Color.primary.opacity(0.08)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredSection = $0 ? sec : nil }
    }

}
