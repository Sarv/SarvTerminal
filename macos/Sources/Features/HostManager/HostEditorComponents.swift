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

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "number.square")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("\(defaultPort)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
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

struct EditorIntRow: View {
    let icon: String
    let placeholder: String
    @Binding var value: Int

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 0
        f.maximum = 65_535
        f.allowsFloats = false
        f.numberStyle = .none
        return f
    }()

    var body: some View {
        RowShell(isInteractive: false, onTap: nil) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(placeholder, value: $value, formatter: Self.formatter)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

// MARK: - Secure field row

struct EditorSecureRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

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
                    } else {
                        // NOTE: SwiftUI's `SecureField` + `.textFieldStyle(.plain)`
                        // is not editable on macOS (you can't focus or type into
                        // it), so back it with an AppKit NSSecureTextField.
                        BorderlessSecureField(placeholder: placeholder, text: $text)
                    }
                }
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
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
