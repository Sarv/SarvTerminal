import SwiftUI

/// Modal form for creating or editing a single keybind.
struct KeybindEditorSheet: View {
    /// Pass an existing entry to edit, nil to create new.
    let editing: KeybindEntry?

    /// Called with the new/updated entry's config-side value (e.g.
    /// `ctrl+c=copy_to_clipboard`) and, if editing, the rawLine to replace.
    let onSave: (_ newValue: String, _ replacing: String?) -> Void
    let onCancel: () -> Void

    @State private var mods: KeybindModifiers = []
    @State private var key: String = ""
    @State private var flags: KeybindFlags = KeybindFlags()
    @State private var actionPickerSearch: String = ""
    @State private var selectedAction: String = ""
    @State private var customActionMode: Bool = false
    @State private var customAction: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    triggerSection
                    flagsSection
                    actionSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
        .onAppear(perform: loadIfEditing)
    }

    private var header: some View {
        HStack {
            Image(systemName: editing == nil ? "plus.circle" : "pencil")
                .foregroundStyle(.tint)
            Text(editing == nil ? "Add keybind" : "Edit keybind")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Trigger")
            HStack(spacing: 8) {
                modToggle("⌃ Ctrl", on: bind(.ctrl))
                modToggle("⌥ Opt", on: bind(.opt))
                modToggle("⇧ Shift", on: bind(.shift))
                modToggle("⌘ Cmd", on: bind(.cmd))
            }
            HStack(spacing: 8) {
                Text("Key")
                    .frame(width: 50, alignment: .leading)
                    .foregroundStyle(.secondary)
                TextField("e.g. a, tab, f1, arrow_left, grave", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Preview: ")
                    .foregroundStyle(.secondary)
                Text(previewString.isEmpty ? "(set modifiers + key)" : previewString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(previewString.isEmpty ? .tertiary : .primary)
            }
        }
    }

    private func modToggle(_ label: String, on: Binding<Bool>) -> some View {
        Toggle(label, isOn: on)
            .toggleStyle(.button)
            .controlSize(.regular)
    }

    private func bind(_ mod: KeybindModifiers) -> Binding<Bool> {
        Binding(
            get: { mods.contains(mod) },
            set: { newValue in
                if newValue { mods.insert(mod) } else { mods.remove(mod) }
            }
        )
    }

    // MARK: - Flags

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Flags (optional)")
            HStack(spacing: 14) {
                Toggle("Global", isOn: $flags.global)
                Toggle("All surfaces", isOn: $flags.all)
                Toggle("Unconsumed", isOn: $flags.unconsumed)
                Toggle("Performable", isOn: $flags.performable)
            }
            .toggleStyle(.checkbox)
            Text(flagsHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var flagsHelp: String {
        """
        Global: works system-wide (macOS only).
        All surfaces: broadcast to every terminal.
        Unconsumed: forward to terminal even when bound.
        Performable: only trigger when the action is doable (e.g. copy when there's a selection).
        """
    }

    // MARK: - Action

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Action")
            HStack {
                Picker("Mode", selection: $customActionMode) {
                    Text("From list").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer()
            }
            if customActionMode {
                customActionView
            } else {
                actionListView
            }
        }
    }

    private var actionListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions…", text: $actionPickerSearch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredActions, id: \.name) { act in
                        actionRow(act)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
        }
    }

    private func actionRow(_ act: KeybindAction) -> some View {
        let isSelected = selectedAction == act.name
        return Button {
            selectedAction = act.name
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(act.label)
                    Text(act.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
                }
                Spacer()
                Text(act.category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customActionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("e.g. text:\\x01, csi:A, goto_tab:3", text: $customAction)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("Action name with optional parameters. See `ghostty +list-actions` for the full list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredActions: [KeybindAction] {
        let q = actionPickerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return kKeybindActions }
        return kKeybindActions.filter {
            $0.label.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    // MARK: - Preview + footer

    private var previewString: String {
        guard !key.isEmpty else { return "" }
        let trigger = KeybindTrigger(modifiers: mods, key: key, chord: nil, flags: flags)
        return trigger.configString
    }

    private var resolvedAction: String {
        customActionMode ? customAction.trimmingCharacters(in: .whitespaces)
                         : selectedAction
    }

    private var canSave: Bool {
        !key.isEmpty && !resolvedAction.isEmpty
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Add" : "Save") {
                let triggerStr = previewString
                let value = "\(triggerStr)=\(resolvedAction)"
                onSave(value, editing?.rawLine)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Load existing

    private func loadIfEditing() {
        guard let e = editing else { return }
        mods = e.trigger.modifiers
        key = e.trigger.key
        flags = e.trigger.flags
        // If action is in our curated list, select it; else go custom.
        if kKeybindActions.contains(where: { $0.name == e.action }) {
            selectedAction = e.action
            customActionMode = false
        } else {
            customAction = e.action
            customActionMode = true
        }
    }
}
