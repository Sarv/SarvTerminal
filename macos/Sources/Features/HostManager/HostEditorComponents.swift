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
                    .stroke(Color.secondary.opacity(hovering && isInteractive ? 0.35 : 0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isInteractive }
            .onTapGesture { onTap?() }
    }
}

// MARK: - Text field row

struct EditorTextRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    /// Fired when the field loses focus — drives the editor's autosave.
    var onEditingEnded: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        RowShell(isInteractive: false, onTap: nil) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .focused($focused)
                    .onChange(of: focused) { nowFocused in
                        if !nowFocused { onEditingEnded?() }
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
                .onChange(of: focused) { nowFocused in
                    if !nowFocused { onEditingEnded?() }
                }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
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

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        RowShell(isInteractive: false, onTap: nil) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
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

    @State private var revealed = false
    @FocusState private var revealedFocused: Bool

    var body: some View {
        RowShell(isInteractive: false, onTap: nil) {
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
                            .onChange(of: revealedFocused) { focused in
                                if !focused { onEditingEnded?() }
                            }
                    } else {
                        // NOTE: SwiftUI's `SecureField` + `.textFieldStyle(.plain)`
                        // is not editable on macOS (you can't focus or type into
                        // it), so back it with an AppKit NSSecureTextField.
                        BorderlessSecureField(placeholder: placeholder, text: $text,
                                              onEditingEnded: onEditingEnded)
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

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
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
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingEnded: onEditingEnded)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onEditingEnded: (() -> Void)?
        init(text: Binding<String>, onEditingEnded: (() -> Void)?) {
            self.text = text
            self.onEditingEnded = onEditingEnded
        }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func controlTextDidEndEditing(_ note: Notification) {
            onEditingEnded?()
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

    var body: some View {
        RowShell(isInteractive: true, onTap: { isOn.toggle() }) {
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
    }
}

// MARK: - Picker row (uses Menu — reliable single-click)

struct EditorPickerRow<T: Hashable>: View {
    let icon: String
    let title: String
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        RowShell(isInteractive: false, onTap: nil) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Menu {
                    ForEach(options, id: \.value) { opt in
                        Button(opt.label) { selection = opt.value }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentLabel)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }
}

// MARK: - Expandable row (tap row → show sub-content beneath)

struct EditorExpandRow<Expanded: View>: View {
    let icon: String
    let title: String
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder var expanded: () -> Expanded

    var body: some View {
        VStack(spacing: 8) {
            RowShell(isInteractive: true, onTap: { isExpanded.toggle() }) {
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
