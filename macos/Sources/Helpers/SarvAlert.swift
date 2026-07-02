import AppKit
import SwiftUI

/// A branded, centered modal alert. Unlike `NSAlert` — which always pins its
/// icon to the top-left corner — this renders the app logo centered above the
/// title, message, and buttons so confirmation popups look symmetric.
///
/// Use `runModal` for a blocking prompt that returns the chosen button, or
/// `beginSheet` to attach it to a window. Buttons are shown top-to-bottom in the
/// order given; the first is treated as primary unless flags say otherwise.
@MainActor
enum SarvAlert {
    /// One button in the alert. `isDefault` renders it prominent and binds it to
    /// Return; `isCancel` binds it to Escape; `isDestructive` tints it red.
    struct Button: Identifiable {
        let id = UUID()
        let title: String
        var isDefault: Bool
        var isDestructive: Bool
        var isCancel: Bool

        init(_ title: String,
             isDefault: Bool = false,
             isDestructive: Bool = false,
             isCancel: Bool = false) {
            self.title = title
            self.isDefault = isDefault
            self.isDestructive = isDestructive
            self.isCancel = isCancel
        }
    }

    /// The user's choice: which button (by index in the `buttons` array) and
    /// whether the optional "remember" checkbox was ticked.
    struct Result {
        let buttonIndex: Int
        let rememberChecked: Bool
    }

    /// Show the alert modally and block until the user chooses. If the window is
    /// dismissed without a choice, returns the cancel button (or the last one).
    @discardableResult
    static func runModal(title: String,
                         message: String = "",
                         buttons: [Button],
                         rememberTitle: String? = nil) -> Result {
        precondition(!buttons.isEmpty, "SarvAlert requires at least one button")
        let fallbackIndex = buttons.firstIndex(where: { $0.isCancel }) ?? buttons.count - 1
        var chosen = Result(buttonIndex: fallbackIndex, rememberChecked: false)

        let panel = makePanel()
        let root = SarvAlertView(
            title: title,
            message: message,
            buttons: buttons,
            rememberTitle: rememberTitle) { index, remember in
                chosen = Result(buttonIndex: index, rememberChecked: remember)
                NSApp.stopModal()
            }

        install(root, in: panel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return chosen
    }

    /// Show the alert as a sheet attached to `parent`, calling `completion` with
    /// the user's choice.
    static func beginSheet(for parent: NSWindow,
                           title: String,
                           message: String = "",
                           buttons: [Button],
                           rememberTitle: String? = nil,
                           completion: @escaping (Result) -> Void) {
        precondition(!buttons.isEmpty, "SarvAlert requires at least one button")
        let panel = makePanel()
        var finished = false
        let root = SarvAlertView(
            title: title,
            message: message,
            buttons: buttons,
            rememberTitle: rememberTitle) { index, remember in
                guard !finished else { return }
                finished = true
                parent.endSheet(panel)
                completion(Result(buttonIndex: index, rememberChecked: remember))
            }

        install(root, in: panel)
        parent.beginSheet(panel) { _ in }
    }

    // MARK: - Presentation plumbing

    private static func install(_ root: SarvAlertView, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting
    }

    private static func makePanel() -> NSPanel {
        let panel = ModalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Borderless panels can't become key by default, which would break keyboard
    /// shortcuts and button focus — so we force it.
    private final class ModalPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}

// MARK: - View

private struct SarvAlertView: View {
    let title: String
    let message: String
    let buttons: [SarvAlert.Button]
    let rememberTitle: String?
    let onChoose: (Int, Bool) -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 16) {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let rememberTitle {
                Toggle(rememberTitle, isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            VStack(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                    SarvAlertButton(button: button) { onChoose(index, remember) }
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }
}

private struct SarvAlertButton: View {
    let button: SarvAlert.Button
    let action: () -> Void

    var body: some View {
        let label = Button(action: action) {
            Text(button.title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)

        Group {
            if button.isDefault {
                label.buttonStyle(.borderedProminent)
            } else {
                label.buttonStyle(.bordered)
            }
        }
        .tint(button.isDestructive ? .red : (button.isDefault ? .accentColor : nil))
        .keyboardShortcut(shortcut)
    }

    private var shortcut: KeyboardShortcut? {
        if button.isDefault { return .defaultAction }
        if button.isCancel { return .cancelAction }
        return nil
    }
}
