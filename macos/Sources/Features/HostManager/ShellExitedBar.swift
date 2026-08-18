import SwiftUI

/// Overlay shown at the bottom of a terminal tab whose shell exited *early*
/// (the signature of a startup crash — e.g. a broken shell rc file). The tab is
/// kept open so its output stays readable instead of silently vanishing, with
/// actions to respawn the shell or close the tab.
struct ShellExitedBar: View {
    /// How long the shell ran before exiting.
    let ranFor: TimeInterval
    let onRestart: () -> Void
    let onClose: () -> Void

    private var ranText: String {
        ranFor < 1 ? "less than a second" : "\(Int(ranFor.rounded()))s"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shell exited")
                    .font(.callout.weight(.semibold))
                Text("It ran for \(ranText) before quitting — likely a startup error (e.g. a broken shell config). The tab is kept open so you can read the output above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Restart", action: onRestart)
                .controlSize(.small)
                .help("Spawn a fresh shell in this tab")
            Button("Close Tab", action: onClose)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
