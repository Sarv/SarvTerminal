import SwiftUI

/// Mini diagram of a saved session's split layout, rendered from the persisted
/// tree — same directions and ratios as the real tab. Each pane card shows
/// what it reopens as: `ssh — <host>` for SSH panes (with the host's OS tile
/// when the saved host still exists), the directory/title for local shells.
struct SessionLayoutPreview: View {
    let session: SavedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
            }
            node(session.layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Recursive layout

    /// AnyView on purpose: a recursive `some View` doesn't compile, and a
    /// preview tree is a handful of nodes.
    private func node(_ n: SavedSession.PaneNode) -> AnyView {
        switch n {
        case .leaf(let pane):
            return AnyView(paneCard(pane))
        case .split(let s):
            let ratio = min(max(s.ratio, 0.1), 0.9)
            return AnyView(GeometryReader { geo in
                if s.direction == .horizontal {
                    HStack(spacing: 3) {
                        node(s.left).frame(width: max(0, (geo.size.width - 3) * ratio))
                        node(s.right)
                    }
                } else {
                    VStack(spacing: 3) {
                        node(s.left).frame(height: max(0, (geo.size.height - 3) * ratio))
                        node(s.right)
                    }
                }
            })
        }
    }

    // MARK: - Pane cards

    @ViewBuilder
    private func paneCard(_ pane: SavedSession.Pane) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            VStack(spacing: 4) {
                if pane.kind == .ssh, let host = sshHost(pane) {
                    // Reuse the OS tile so the preview matches the host cards.
                    HostOSIconView(host: host, side: 22)
                } else {
                    Image(systemName: pane.kind == .ssh ? "network" : "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(pane.kind == .ssh ? Color.orange : .secondary)
                }
                Text(label(for: pane))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
            }
            .padding(2)
        }
    }

    private func sshHost(_ pane: SavedSession.Pane) -> SavedHost? {
        guard let id = pane.hostID else { return nil }
        return SavedHostsStore.shared.host(withID: id)
    }

    private func label(for pane: SavedSession.Pane) -> String {
        switch pane.kind {
        case .ssh:
            if let host = sshHost(pane) { return "ssh — \(host.displayLabel)" }
            // Fallback: the target from the raw command ("ssh -p 22 user@host").
            if let cmd = pane.command,
               let target = cmd.split(separator: " ").last(where: { $0.contains("@") || !$0.hasPrefix("-") }) {
                return "ssh — \(target)"
            }
            return pane.title.map { "ssh — \($0)" } ?? "ssh"
        case .local:
            if let title = pane.title, !title.isEmpty { return title }
            if let dir = pane.workingDirectory, !dir.isEmpty {
                let home = NSHomeDirectory()
                return dir == home ? "~" : (dir as NSString).lastPathComponent
            }
            return "Local"
        }
    }
}
