import SwiftUI
import AppKit

/// Termius-style SSH connection popup over a Vaults terminal tab: an icon
/// header with Copy-logs, a horizontal Connect → Authenticate → Session stepper,
/// an inline connection-log box, and Close / Edit host / Start over actions.
/// Shown for the whole connection lifecycle and again on disconnect/failure;
/// hidden only while `connected` so the live terminal shows.
struct SSHConnectionView: View {
    @ObservedObject var model: SSHConnectionModel
    @ObservedObject private var background = BackgroundDisplayStore.shared
    @ObservedObject private var tabs = VaultsTabsModel.shared
    let controller: SSHConnectionController
    /// Abort and close the tab (Close button).
    let onCancel: () -> Void

    @FocusState private var passwordFocused: Bool

    /// Where the "Documentation" link points for connection troubleshooting.
    private let docsURL = URL(string: "https://www.openssh.com/manual.html")!

    var body: some View {
        if model.showsCard {
            ZStack {
                backdrop
                // Scroll when the pane is too short for the card (e.g. a 4-way
                // split) so it's never clipped to a sliver; centred when it fits.
                GeometryReader { geo in
                    ScrollView(.vertical, showsIndicators: false) {
                        card
                            .padding(24)
                            .frame(maxWidth: 460)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.ultraThinMaterial))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
            }
            .onAppear { focusPasswordIfNeeded() }
            .onChange(of: model.stage) { _ in focusPasswordIfNeeded() }
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            if background.useShared, let image = background.sharedImage {
                Color.black
                Image(nsImage: image).resizable().scaledToFill().opacity(background.imageVisibility)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .clipped()
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 24) {
            headerRow
            stepper
            // The middle area holds either the stage content (password / status)
            // or the logs panel when "Show logs" is on — with a reserved minimum
            // height so toggling logs doesn't jump the layout.
            stageBody
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
            buttonRow
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.logEntries.isEmpty {
                if model.showLogs {
                    Button("Copy logs") { copyLogs() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Show logs") { withAnimation(.easeInOut(duration: 0.15)) { model.showLogs = true } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var subtitle: String {
        if let host = model.host { return "SSH \(host.hostname):\(host.port)" }
        return "SSH"
    }

    // MARK: Stepper

    private var stepper: some View {
        HStack(spacing: 0) {
            node(0, icon: "powerplug.fill")
            connector(0)
            node(1, icon: "lock.fill")
            connector(1)
            node(2, icon: "terminal.fill")
        }
        .frame(maxWidth: 320)
    }

    private func node(_ index: Int, icon: String) -> some View {
        Circle()
            .fill(nodeColor(index))
            .frame(width: 34, height: 34)
            .overlay(Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white))
    }

    private func connector(_ index: Int) -> some View {
        Rectangle()
            .fill(connectorColor(index))
            .frame(height: 3)
            .frame(maxWidth: .infinity)
    }

    private func nodeColor(_ index: Int) -> Color {
        if isFailedState { return .red }
        switch [connectStatus, authStatus, sessionStatus][index] {
        case .success, .inProgress: return .accentColor
        case .failure:              return .red
        case .pending:              return Color.secondary.opacity(0.35)
        }
    }

    /// Connector after node `index` is filled once that node is complete.
    private func connectorColor(_ index: Int) -> Color {
        if isFailedState { return .red }
        let done = [connectStatus, authStatus][index] == .success
        return done ? .accentColor : Color.secondary.opacity(0.25)
    }

    // MARK: Stage body

    @ViewBuilder
    private var stageBody: some View {
        if model.showLogs {
            logsPanel
        } else {
            stageContent
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch model.stage {
        case .needsPassword:
            passwordSection
        case .needsHostKey(let info):
            hostKeySection(info)
        case .connecting:
            Text("Connecting…").font(.callout).foregroundStyle(.secondaryText)
        case .failed(let f):
            VStack(spacing: 6) {
                Text(f.title).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text(f.detail).font(.caption).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
                if model.autoReconnecting { reconnectStatusLine }
            }
        case .disconnected:
            VStack(spacing: 6) {
                Text("Session ended").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text("The SSH session has closed.").font(.caption).foregroundStyle(.secondaryText)
                if model.autoReconnecting { reconnectStatusLine }
            }
        case .connected:
            EmptyView()
        }
    }

    /// "Reconnecting in Ns…" line shown while the auto-reconnect loop counts down.
    private var reconnectStatusLine: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Reconnecting in \(model.reconnectSecondsRemaining)s… (attempt \(model.reconnectAttempts))")
                .font(.caption).foregroundStyle(.secondaryText)
        }
        .padding(.top, 2)
    }

    private func hostKeySection(_ info: HostKeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Are you sure you want to connect?")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondaryText)

            if info.changed {
                Text("⚠︎ The host key for \(info.host) has changed. This could be a man-in-the-middle attack — or the server was reinstalled.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The authenticity of \(info.host) can not be established.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(info.keyType.isEmpty ? "Key" : info.keyType.uppercased()) fingerprint is SHA256:")
                .foregroundStyle(.secondaryText)
            Text(info.fingerprint.replacingOccurrences(of: "SHA256:", with: ""))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !info.changed {
                Text("Do you want to add it to the list of known hosts?")
                    .foregroundStyle(.secondaryText)
            }

            HStack {
                Button("Close") { onCancel() }
                Spacer()
                if info.changed {
                    Button("Replace and continue") { controller.replaceHostKey() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { controller.acceptHostKey(save: false) }
                    Button("Add and continue") { controller.acceptHostKey(save: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var passwordSection: some View {
        VStack(spacing: 10) {
            SecureField("Password", text: $model.passwordField)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit { controller.submitPassword() }
            if model.passwordAttempts > 0 {
                let remaining = model.maxPasswordAttempts - model.passwordAttempts
                Text("Incorrect password — \(remaining) attempt\(remaining == 1 ? "" : "s") left")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("This host is set to “Ask”, so you'll enter the password each time. To save it, edit the host and choose “Password”.")
                .font(.caption2).foregroundStyle(.tertiaryText)
                .multilineTextAlignment(.center)
        }
    }

    /// A prominent, plain-language failure card shown atop the logs (and as the
    /// collapsed stage content) so the reason is clear at a glance.
    @ViewBuilder
    private var failureSummary: some View {
        switch model.stage {
        case .failed(let f):
            summaryCard(title: f.title, detail: f.detail)
        case .disconnected:
            summaryCard(title: "Session ended", detail: "The SSH session has closed.")
        default:
            EmptyView()
        }
    }

    private func summaryCard(title: String, detail: String) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.12)))
    }

    /// Logs replace the stage content when "Show logs" is on.
    private var logsPanel: some View {
        VStack(spacing: 10) {
            // A clear, human-readable failure summary above the raw log lines, so
            // the error is legible without parsing ssh's jargon.
            failureSummary
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.logEntries.isEmpty {
                        Text("Waiting for output…").font(.system(size: 12)).foregroundStyle(.secondaryText)
                    } else {
                        ForEach(model.logEntries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(entry.color)
                                    .frame(width: 16)
                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.22)))

            if isFailedState {
                Text(.init("See the [Documentation](\(docsURL.absoluteString)) to learn more about common connection issues."))
                    .font(.caption).foregroundStyle(.secondaryText).tint(.accentColor)
                    .multilineTextAlignment(.center)
            }

            Button("Hide logs") { withAnimation(.easeInOut(duration: 0.15)) { model.showLogs = false } }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondaryText)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttonRow: some View {
        switch model.stage {
        case .needsPassword:
            HStack(spacing: 10) {
                Button("Close") { onCancel() }.keyboardShortcut(.cancelAction)
                // Always offer Edit host while entering a password for a saved
                // host (the saved password/port may be wrong).
                if model.host != nil {
                    Button("Edit host") { controller.editHost() }
                }
                Spacer()
                Button("Connect") { controller.submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.passwordField.isEmpty)
            }
        case .connecting:
            HStack {
                Button("Close") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
            }
        case .needsHostKey:
            // Buttons are part of the host-key card itself.
            EmptyView()
        case .failed, .disconnected:
            HStack(spacing: 10) {
                Button("Close") { onCancel() }.keyboardShortcut(.cancelAction)
                if model.host != nil {
                    Button("Edit host") { controller.editHost() }
                }
                Spacer()
                // When several sessions dropped together (e.g. the network
                // blipped), one click recovers them all.
                if tabs.reconnectablePopupCount > 1 {
                    Button("Reconnect all (\(tabs.reconnectablePopupCount))") {
                        tabs.reconnectAllPopups()
                    }
                }
                if model.autoReconnecting {
                    // Auto-retry loop is running: let the user stop it or skip
                    // the countdown and try right now.
                    Button("Stop") { controller.stopAutoReconnect() }
                    Button("Reconnect now") { controller.retryNow() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start over") { controller.reconnect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .connected:
            EmptyView()
        }
    }

    // MARK: Progress states (drive the stepper colors)

    private var isAwaitingInput: Bool { if case .needsPassword = model.stage { return true }; return false }
    private var isFailedState: Bool {
        switch model.stage { case .failed, .disconnected: return true; default: return false }
    }
    private var sawAuth: Bool {
        model.logEntries.contains { $0.text.lowercased().hasPrefix("authenticating") }
    }

    private var connectStatus: SSHStepStatus {
        if isAwaitingInput { return .pending }
        switch model.stage {
        case .connecting: return .success      // TCP connect is quick; auth carries progress
        case .connected:  return .success
        case .failed, .disconnected: return .failure
        default: return .pending
        }
    }

    private var authStatus: SSHStepStatus {
        if isAwaitingInput { return .pending }
        switch model.stage {
        case .connected: return .success
        case .connecting: return sawAuth ? .inProgress : .pending
        case .failed, .disconnected: return .failure
        default: return .pending
        }
    }

    private var sessionStatus: SSHStepStatus {
        switch model.stage {
        case .connected: return .success
        case .failed, .disconnected: return .failure
        default: return .pending
        }
    }

    // MARK: Actions

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logCopyText, forType: .string)
    }

    private func focusPasswordIfNeeded() {
        guard case .needsPassword = model.stage else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { passwordFocused = true }
    }
}
