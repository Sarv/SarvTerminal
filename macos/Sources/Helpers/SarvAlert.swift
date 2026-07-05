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

    /// The user's choice: which button (by index in the `buttons` array),
    /// whether the optional "remember" checkbox was ticked, and the text of
    /// the optional input field.
    struct Result {
        let buttonIndex: Int
        let rememberChecked: Bool
        var inputText: String = ""
    }

    /// Show the alert modally and block until the user chooses. If the window is
    /// dismissed without a choice, returns the cancel button (or the last one).
    @discardableResult
    static func runModal(title: String,
                         message: String = "",
                         buttons: [Button],
                         rememberTitle: String? = nil,
                         rememberInitial: Bool = false,
                         inputInitial: String? = nil) -> Result {
        precondition(!buttons.isEmpty, "SarvAlert requires at least one button")
        let fallbackIndex = buttons.firstIndex(where: { $0.isCancel }) ?? buttons.count - 1
        var chosen = Result(buttonIndex: fallbackIndex, rememberChecked: false)

        let panel = makePanel()
        let root = SarvAlertView(
            title: title,
            message: message,
            buttons: buttons,
            rememberTitle: rememberTitle,
            rememberInitial: rememberInitial,
            inputInitial: inputInitial) { index, remember, text in
                chosen = Result(buttonIndex: index, rememberChecked: remember, inputText: text)
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


    /// Non-blocking variant — REQUIRED when calling from a SwiftUI button
    /// action, gesture, or onChange: starting the app-modal session inside
    /// SwiftUI's event pass leaves the panel deaf to mouse events (buttons
    /// render but never receive clicks). This defers one runloop turn so the
    /// triggering event finishes first, then runs the normal modal.
    static func present(title: String,
                        message: String = "",
                        buttons: [Button],
                        rememberTitle: String? = nil,
                        rememberInitial: Bool = false,
                        inputInitial: String? = nil,
                        completion: @escaping (Result) -> Void = { _ in }) {
        DispatchQueue.main.async {
            completion(runModal(title: title, message: message, buttons: buttons,
                                rememberTitle: rememberTitle, rememberInitial: rememberInitial,
                                inputInitial: inputInitial))
        }
    }

    /// Show the alert as a sheet attached to `parent`, calling `completion` with
    /// the user's choice. `inputInitial` (non-nil) adds a text field under the
    /// message; its final text comes back in `Result.inputText`.
    static func beginSheet(for parent: NSWindow,
                           title: String,
                           message: String = "",
                           buttons: [Button],
                           rememberTitle: String? = nil,
                           inputInitial: String? = nil,
                           completion: @escaping (Result) -> Void) {
        precondition(!buttons.isEmpty, "SarvAlert requires at least one button")
        let panel = makePanel()
        var finished = false
        let root = SarvAlertView(
            title: title,
            message: message,
            buttons: buttons,
            rememberTitle: rememberTitle,
            rememberInitial: false,
            inputInitial: inputInitial) { index, remember, text in
                guard !finished else { return }
                finished = true
                parent.endSheet(panel)
                completion(Result(buttonIndex: index, rememberChecked: remember, inputText: text))
            }

        install(root, in: panel)
        parent.beginSheet(panel) { _ in }
    }

    /// Async variant of `beginSheet` for callers using structured concurrency.
    @MainActor
    static func beginSheet(for parent: NSWindow,
                           title: String,
                           message: String = "",
                           buttons: [Button],
                           rememberTitle: String? = nil,
                           inputInitial: String? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            beginSheet(for: parent, title: title, message: message,
                       buttons: buttons, rememberTitle: rememberTitle,
                       inputInitial: inputInitial) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Presentation plumbing

    private static func install(_ root: SarvAlertView, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting
        // The insertion caret in the input field: the panel's shared field
        // editor defaults to a color that's invisible on the dark card, so pin
        // it to the adaptive label color.
        if let editor = panel.fieldEditor(true, for: nil) as? NSTextView {
            editor.insertionPointColor = .labelColor
        }
    }

    private static func makePanel() -> NSPanel {
        // NOT .borderless: borderless windows get degraded mouse-event routing
        // for SwiftUI content under NSApp.runModal (buttons render but clicks
        // never fire). A titled window with hidden chrome behaves like a normal
        // key window — same card look, working clicks.
        let panel = ModalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
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
    /// Initial state of the remember checkbox.
    var rememberInitial: Bool = false
    /// Non-nil shows a text field under the message, pre-filled with this value.
    let inputInitial: String?
    let onChoose: (Int, Bool, String) -> Void

    @State private var remember = false
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                // The icon asset carries transparent margins on every side —
                // pull the title up so the visual gap matches the spacing.
                .padding(.vertical, -10)

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

            if inputInitial != nil {
                TextField("", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($inputFocused)
                    // Return in the field = the default button.
                    .onSubmit { chooseDefault() }
                    .onAppear {
                        inputText = inputInitial ?? ""
                        DispatchQueue.main.async { inputFocused = true }
                    }
            }

            if let rememberTitle {
                Toggle(rememberTitle, isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onAppear { remember = rememberInitial }
            }

            // One or two buttons sit side-by-side (macOS convention: cancel on
            // the left, primary action on the right); three or more stack.
            Group {
                if buttons.count <= 2 {
                    HStack(spacing: 10) {
                        ForEach(rowOrdered, id: \.element.id) { index, button in
                            SarvAlertButton(button: button) { onChoose(index, remember, inputText) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                            SarvAlertButton(button: button) { onChoose(index, remember, inputText) }
                        }
                    }
                }
            }
            // Actions sit apart from the content above them.
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    /// Display order for the side-by-side row: cancel/secondary on the left,
    /// the default action on the right — regardless of the caller's array
    /// order. Original indices are preserved for the choice callback.
    private var rowOrdered: [(offset: Int, element: SarvAlert.Button)] {
        Array(buttons.enumerated()).sorted { a, b in
            func rank(_ btn: SarvAlert.Button) -> Int {
                if btn.isCancel { return 0 }
                if btn.isDefault { return 2 }
                return 1
            }
            return rank(a.element) < rank(b.element)
        }
    }

    private func chooseDefault() {
        guard let idx = buttons.firstIndex(where: { $0.isDefault }) else { return }
        onChoose(idx, remember, inputText)
    }
}

private struct SarvAlertButton: View {
    let button: SarvAlert.Button
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // Explicit pill styling — the system bordered styles render
        // inconsistently on borderless panels (destructive buttons could lose
        // their fill entirely), so every button draws its own background.
        Button(action: action) {
            Text(button.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(fillColor.opacity(hovering ? 1.0 : 0.88)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut)
    }

    private var fillColor: Color {
        if button.isDestructive { return .red }
        if button.isDefault { return .accentColor }
        return Color.secondary.opacity(0.25)
    }

    private var textColor: Color {
        (button.isDestructive || button.isDefault) ? .white : .primary
    }

    private var shortcut: KeyboardShortcut? {
        if button.isDefault { return .defaultAction }
        if button.isCancel { return .cancelAction }
        return nil
    }
}
