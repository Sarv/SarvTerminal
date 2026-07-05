import SwiftUI
import AppKit

// MARK: - Card

/// Termius-style grouped card. Use one per logical group of fields.
struct EditorCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
            VStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, title == nil ? 12 : 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

// MARK: - Row shell (rounded pill background, hover highlight)

private struct RowShell<Content: View>: View {
    let isInteractive: Bool
    let onTap: (() -> Void)?
    /// Row contains the focused input — accent border, same as the tags field.
    var isFocused: Bool = false
    /// Cursor while hovering: I-beam for text rows, pointing hand for
    /// dropdowns/toggles. nil keeps the arrow.
    var hoverCursor: NSCursor? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && isInteractive ? Color.secondary.opacity(0.10) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.accentColor.opacity(0.7)
                                      : Color.secondary.opacity(hovering && isInteractive ? 0.35 : 0.22),
                            lineWidth: isFocused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside && isInteractive
            }
            // Continuous set (not push/pop): the embedded NSTextField's own
            // cursor rects keep resetting a pushed cursor to the arrow.
            .onContinuousHover { phase in
                guard let hoverCursor else { return }
                switch phase {
                case .active: hoverCursor.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .onTapGesture { onTap?() }
    }
}

// MARK: - Editor focus chain

/// Every keyboard-focusable stop in the host editor. The editor's `focusOrder`
/// decides the actual Tab sequence. Shared by the row components so
/// Tab/Shift+Tab can move focus programmatically — the mixed SwiftUI/AppKit
/// fields break the native key-view loop (Shift+Tab dead-ends).
enum HostEditorFocusField: Hashable {
    case hostname, label, group, tags, note
    case port, username, authMethod, password, identityFile, browseKey, forwardAgent
    case startupExpander, startup
    case osPicker, themePicker
    case advancedExpander
    case strictHostKey, connectTimeout, keepAlive, proxyJump, compression, forceTTY
    case localForwardsExpander, localForwards
    case remoteForwardsExpander, remoteForwards
    case socksPort
}

/// Applies `.focused(focus, equals: field)` only when an external focus tag is
/// provided — rows outside the host editor (e.g. the group editor) pass none.
private struct EditorExternalFocus: ViewModifier {
    var focus: FocusState<HostEditorFocusField?>.Binding?
    var field: HostEditorFocusField?

    func body(content: Content) -> some View {
        if let focus, let field {
            content.focused(focus, equals: field)
        } else {
            content
        }
    }
}

extension View {
    func editorFocus(_ focus: FocusState<HostEditorFocusField?>.Binding?,
                     _ field: HostEditorFocusField?) -> some View {
        modifier(EditorExternalFocus(focus: focus, field: field))
    }
}

/// AppKit-level Tab/Shift+Tab interception while the editor is on screen.
/// SwiftUI's `onKeyPress` never sees Tab on macOS text fields — the field
/// editor consumes it first — so a local event monitor is the only reliable
/// hook. `inSecureField` reports when the AppKit password field holds first
/// responder (SwiftUI's focus state doesn't track it, so the caller must
/// anchor the move itself). `onTab` returns whether it moved focus.
struct EditorTabKeyMonitor: ViewModifier {
    let onTab: (_ backward: Bool, _ inSecureField: Bool) -> Bool
    @State private var monitor: Any? = nil

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 48 else { return event }   // Tab
                    // Don't hijack Tab inside popovers (theme search, group
                    // picker) — those are separate windows.
                    if event.window?.className.contains("Popover") == true { return event }
                    let fr = event.window?.firstResponder
                    let inSecure = fr is NSSecureTextField
                        || (fr as? NSTextView)?.delegate is NSSecureTextField
                    let backward = event.modifierFlags.contains(.shift)
                    return onTab(backward, inSecure) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Return/Space activates the control when it has keyboard focus (macOS 14+).
/// Shared by every focusable non-text stop: toggles, expanders, popover
/// pickers — so activation behavior never diverges.
struct ActivateOnKeyPress: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.return) { action(); return .handled }
                .onKeyPress(.space) { action(); return .handled }
        } else {
            content
        }
    }
}

/// ↑/↓ cycles a focused picker's selection without opening its menu — the
/// whole form stays fillable from the keyboard (macOS 14+).
struct CycleOnArrowKeys: ViewModifier {
    let cycle: (_ delta: Int) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.downArrow) { cycle(1); return .handled }
                .onKeyPress(.upArrow) { cycle(-1); return .handled }
        } else {
            content
        }
    }
}

// MARK: - Text field row

struct EditorTextRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    /// Grab keyboard focus when the row appears — set on the FIRST field of a
    /// form so it's immediately typable without a mouse click.
    var autoFocus: Bool = false
    /// Fired when the field loses focus — drives the editor's autosave.
    var onEditingEnded: (() -> Void)? = nil
    /// External focus tag for the editor's Tab/Shift+Tab chain.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @FocusState private var focused: Bool

    var body: some View {
        RowShell(isInteractive: false, onTap: nil, isFocused: focused, hoverCursor: .iBeam) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .focused($focused)
                    .editorFocus(focus, field)
                    .onChange(of: focused) { nowFocused in
                        if !nowFocused { onEditingEnded?() }
                    }
                    .onAppear {
                        guard autoFocus else { return }
                        // Deferred past the panel's slide-in transition —
                        // focusing mid-animation silently fails.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            focused = true
                        }
                    }
            }
        }
    }
}

// MARK: - Port field (placeholder = 22)

/// Specialised port input: shows "22" as the placeholder when the value
/// equals the default, and treats an empty field as "use default 22".
/// Matches Termius behavior — you only see a real number when the user
/// has deliberately overridden it.
struct EditorPortField: View {
    @Binding var value: Int
    var defaultPort: Int = 22
    /// Fired when the field loses focus — drives the editor's autosave.
    var onEditingEnded: (() -> Void)? = nil
    /// External focus tag for the editor's Tab/Shift+Tab chain.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "number.square")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("\(defaultPort)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .editorFocus(focus, field)
                .onChange(of: focused) { nowFocused in
                    if !nowFocused { onEditingEnded?() }
                }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.22),
                        lineWidth: focused ? 1.5 : 1)
        )
        // Hover must cover the whole pill (incl. padding), not just the glyphs.
        .contentShape(Rectangle())
        .hoverCursor(.iBeam)
        .onAppear {
            // Show empty (so placeholder is visible) when value is the default.
            text = value == defaultPort ? "" : "\(value)"
        }
        .onChange(of: text) { newValue in
            if newValue.isEmpty {
                value = defaultPort
            } else if let n = Int(newValue), n > 0, n <= 65_535 {
                value = n
            }
        }
    }
}

// MARK: - Number field row

/// Int input where 0 means "unset": the field shows the placeholder (not a
/// literal `0`) until the user types a real value, and clearing it restores 0.
struct EditorIntRow: View {
    let icon: String
    let placeholder: String
    @Binding var value: Int
    /// Fired when the field loses focus — drives the editor's autosave.
    var onEditingEnded: (() -> Void)? = nil
    /// External focus tag for the editor's Tab/Shift+Tab chain.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        RowShell(isInteractive: false, onTap: nil, isFocused: focused, hoverCursor: .iBeam) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .editorFocus(focus, field)
                    .onChange(of: focused) { nowFocused in
                        if !nowFocused { onEditingEnded?() }
                    }
            }
        }
        .onAppear {
            text = value == 0 ? "" : "\(value)"
        }
        .onChange(of: text) { newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(5))
            if digits != newValue { text = digits }
            value = min(Int(digits) ?? 0, 65_535)
        }
    }
}

// MARK: - Secure field row

struct EditorSecureRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    /// Fired when the field loses focus — lets the editor defer "required"
    /// validation until the user has actually visited the field.
    var onEditingEnded: (() -> Void)? = nil
    /// External focus tag for the editor's Tab/Shift+Tab chain.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil
    /// Tab pressed INSIDE the AppKit secure field (true = Shift+Tab) — the
    /// editor moves its focus chain, since AppKit can't see SwiftUI fields.
    var onTabOut: ((_ backward: Bool) -> Void)? = nil

    @State private var revealed = false
    @FocusState private var revealedFocused: Bool
    /// Focus of the AppKit-backed hidden field (reported by its delegate).
    @State private var secureFocused = false

    var body: some View {
        RowShell(isInteractive: false, onTap: nil,
                 isFocused: revealed ? revealedFocused : secureFocused,
                 hoverCursor: .iBeam) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Group {
                    if revealed {
                        TextField(placeholder, text: $text)
                            .textFieldStyle(.plain)
                            .focused($revealedFocused)
                            .editorFocus(focus, field)
                            .onChange(of: revealedFocused) { focused in
                                if !focused { onEditingEnded?() }
                            }
                    } else {
                        // NOTE: SwiftUI's `SecureField` + `.textFieldStyle(.plain)`
                        // is not editable on macOS (you can't focus or type into
                        // it), so back it with an AppKit NSSecureTextField.
                        // The `.focusable()` anchor lets SwiftUI ACCEPT the
                        // chain focus (otherwise Tab-to-password snaps back to
                        // the previous stop); `wantsFocus` then hands the real
                        // first responder to the AppKit field.
                        BorderlessSecureField(placeholder: placeholder, text: $text,
                                              onEditingEnded: onEditingEnded,
                                              wantsFocus: focus != nil && field != nil
                                                  && focus?.wrappedValue == field,
                                              onTabOut: onTabOut,
                                              onFocusChanged: { secureFocused = $0 })
                            .focusable()
                            .editorFocus(focus, field)
                    }
                }
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide password" : "Show password")
            }
        }
    }
}

// MARK: - Borderless secure field (AppKit-backed)

/// A plain, borderless secure text field. Wraps `NSSecureTextField` because
/// SwiftUI's `SecureField().textFieldStyle(.plain)` is not editable on macOS.
struct BorderlessSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onEditingEnded: (() -> Void)? = nil
    /// The editor's focus chain points at this field — grab first responder.
    var wantsFocus: Bool = false
    /// Tab/Shift+Tab pressed inside the field (AppKit side of the chain).
    var onTabOut: ((_ backward: Bool) -> Void)? = nil
    /// Reports begin/end editing so the row can draw its focus border.
    var onFocusChanged: ((Bool) -> Void)? = nil

    /// Reports first-responder acquisition (click OR programmatic focus) —
    /// `controlTextDidBeginEditing` only fires on the first keystroke, which
    /// left the focus border missing until the user typed.
    final class FocusReportingSecureField: NSSecureTextField {
        var onFocusGained: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocusGained?() }
            return ok
        }
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = FocusReportingSecureField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.onFocusGained = { [weak coordinator = context.coordinator] in
            coordinator?.onFocusChanged?(true)
        }
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        context.coordinator.onTabOut = onTabOut
        context.coordinator.onFocusChanged = onFocusChanged
        // Focus chain arrived here (Tab from a SwiftUI field): become first
        // responder ONCE per false→true transition. Without the edge trigger,
        // a stale render with `wantsFocus` still true re-grabs focus right
        // after tabbing OUT (the resign makes `currentEditor` nil again),
        // trapping the user in the field.
        if wantsFocus {
            if !context.coordinator.didRequestFocus {
                context.coordinator.didRequestFocus = true
                DispatchQueue.main.async {
                    guard field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                }
            }
        } else {
            context.coordinator.didRequestFocus = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingEnded: onEditingEnded,
                    onTabOut: onTabOut, onFocusChanged: onFocusChanged)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onEditingEnded: (() -> Void)?
        var onTabOut: ((Bool) -> Void)?
        var onFocusChanged: ((Bool) -> Void)?
        /// Edge trigger for `wantsFocus` — one first-responder grab per
        /// false→true transition (see `updateNSView`).
        var didRequestFocus = false

        init(text: Binding<String>, onEditingEnded: (() -> Void)?,
             onTabOut: ((Bool) -> Void)?, onFocusChanged: ((Bool) -> Void)?) {
            self.text = text
            self.onEditingEnded = onEditingEnded
            self.onTabOut = onTabOut
            self.onFocusChanged = onFocusChanged
        }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func controlTextDidBeginEditing(_ note: Notification) {
            onFocusChanged?(true)
        }
        func controlTextDidEndEditing(_ note: Notification) {
            onFocusChanged?(false)
            onEditingEnded?()
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTabOut?(false); return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onTabOut?(true); return true
            }
            return false
        }
    }
}

// MARK: - Bool row (tap anywhere)

/// Bool row with a real macOS switch on the right + the entire row as a
/// click target. The toggle disables its own hit testing so taps always
/// fall through to the row's onTapGesture — no more "needs two clicks".
struct EditorBoolRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    /// External focus tag — Space/Return toggles while chain-focused.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    private var chainFocused: Bool { field != nil && focus?.wrappedValue == field }

    var body: some View {
        RowShell(isInteractive: true, onTap: { isOn.toggle() }, isFocused: chainFocused,
                 hoverCursor: .pointingHand) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .editorFocus(focus, field)
        .modifier(ActivateOnKeyPress { isOn.toggle() })
    }
}

// MARK: - Picker row (uses Menu — reliable single-click)

struct EditorPickerRow<T: Hashable>: View {
    let icon: String
    let title: String
    @Binding var selection: T
    let options: [(value: T, label: String)]
    /// External focus tag — ↑/↓ cycles the selection while chain-focused.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    private var chainFocused: Bool { field != nil && focus?.wrappedValue == field }

    @State private var isPresented = false

    var body: some View {
        // A plain row + popover list (NOT a SwiftUI Menu — macOS flattens
        // complex Menu labels, dropping the value capsule entirely). The whole
        // row opens the picker; the capsule makes it read as a select box.
        RowShell(isInteractive: true, onTap: { isPresented = true }, isFocused: chainFocused) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                // Value styled like a native popup button — the visual cue
                // that this row is a selection control. The select cursor
                // shows over THIS control only, not the whole row.
                HStack(spacing: 4) {
                    Text(currentLabel)
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(NSColor.controlColor))
                )
                .hoverCursor(.pointingHand)
            }
        }
        .focusable()
        .editorFocus(focus, field)
        .modifier(ActivateOnKeyPress { isPresented = true })
        .modifier(CycleOnArrowKeys { cycle($0) })
        // RULE: a selection control closes its dropdown the moment the value
        // changes — no matter how it changed (click, arrow-cycling, …).
        .onChange(of: selection) { _ in isPresented = false }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.value) { opt in
                    Button {
                        selection = opt.value
                        isPresented = false
                    } label: {
                        HStack {
                            Text(opt.label)
                            Spacer()
                            if opt.value == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowHover()
                }
            }
            .padding(6)
            .frame(minWidth: 220)
        }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }

    private func cycle(_ delta: Int) {
        guard !options.isEmpty else { return }
        let i = options.firstIndex { $0.value == selection } ?? 0
        let j = (i + delta + options.count) % options.count
        selection = options[j].value
    }
}

// MARK: - Expandable row (tap row → show sub-content beneath)

struct EditorExpandRow<Expanded: View>: View {
    let icon: String
    let title: String
    let summary: String
    @Binding var isExpanded: Bool
    /// External focus tag — Space/Return expands/collapses while chain-focused.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil
    @ViewBuilder var expanded: () -> Expanded

    private var chainFocused: Bool { field != nil && focus?.wrappedValue == field }

    var body: some View {
        VStack(spacing: 8) {
            RowShell(isInteractive: true, onTap: { isExpanded.toggle() }, isFocused: chainFocused,
                     hoverCursor: .pointingHand) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title)
                    Spacer()
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if isExpanded {
                expanded()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .focusable()
        .editorFocus(focus, field)
        .modifier(ActivateOnKeyPress { isExpanded.toggle() })
    }
}

// MARK: - Hover cursor

/// Push a cursor while hovering a control: `.iBeam` for text inputs,
/// `.pointingHand` for dropdowns and other clickable rows.
struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        // Continuous set (not push/pop) — AppKit cursor rects under the
        // pointer keep resetting a pushed cursor.
        content.onContinuousHover { phase in
            switch phase {
            case .active: cursor.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}

// MARK: - Hover highlight for list rows

/// Standard hover highlight for rows in dropdown lists, suggestion lists and
/// popover menus — every clickable list row should carry this so hover state
/// is always visible.
struct ListRowHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 6
    var isEnabled: Bool = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering && isEnabled ? Color.secondary.opacity(0.14) : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Hover highlight for a clickable list/menu row.
    func listRowHover(cornerRadius: CGFloat = 6, isEnabled: Bool = true) -> some View {
        modifier(ListRowHoverModifier(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}

// MARK: - Keyboard navigation for suggestion/option lists

/// Arrow-key navigation for a list attached to a focused control (tag
/// suggestions, group picker, …): ↑/↓ move the highlight, Return picks it.
/// `highlighted == -1` means nothing highlighted — Return then falls through
/// to the control's own submit action. `isSelectable` lets pickers skip
/// disabled rows. The SHARED implementation for every in-form list, so
/// keyboard behavior never diverges between fields (macOS 14+; earlier
/// systems keep mouse behavior).
struct ListKeyNavigationModifier: ViewModifier {
    let count: Int
    @Binding var highlighted: Int
    var isSelectable: (Int) -> Bool = { _ in true }
    let onPick: (Int) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    guard highlighted >= 0, highlighted < count else { return .ignored }
                    onPick(highlighted)
                    return .handled
                }
        } else {
            content
        }
    }

    @available(macOS 14.0, *)
    private func move(_ delta: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        var idx = highlighted
        // Scan in `delta` direction for the next selectable row (skip disabled).
        for _ in 0..<count {
            idx += delta
            if idx < 0 || idx >= count { break }
            if isSelectable(idx) {
                highlighted = idx
                return .handled
            }
        }
        // Walked off the top → clear the highlight (back to free typing).
        if delta < 0 { highlighted = -1 }
        return .handled
    }
}

extension View {
    /// Arrow-key + Return navigation for the list under a focused control.
    func listKeyNavigation(
        count: Int,
        highlighted: Binding<Int>,
        isSelectable: @escaping (Int) -> Bool = { _ in true },
        onPick: @escaping (Int) -> Void
    ) -> some View {
        modifier(ListKeyNavigationModifier(
            count: count, highlighted: highlighted,
            isSelectable: isSelectable, onPick: onPick))
    }
}

// MARK: - Subheading inside a card

struct EditorSubheading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
