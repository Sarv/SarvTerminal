import SwiftUI

/// Inline editor for a `HostGroup`. Same in-window placement as
/// `HostEditorView` — replaces the section content (never a sheet).
struct GroupEditorView: View {
    @Binding var draft: HostGroup
    let isNew: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    EditorCard("Group") {
                        HStack(alignment: .center, spacing: 12) {
                            // Live-updating swatch reflects color + icon choice.
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(GroupColorPalette.color(for: draft.colorHex).opacity(0.85))
                                    .frame(width: 40, height: 40)
                                Image(systemName: draft.iconSystemName.isEmpty
                                      ? "folder.fill" : draft.iconSystemName)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            EditorTextRow(icon: "tag",
                                          placeholder: "Group name",
                                          text: $draft.name,
                                          autoFocus: true)
                        }
                        ParentGroupPicker(
                            groupID: $draft.parentID,
                            excludedID: isNew ? nil : draft.id,
                            placeholder: "No parent (root group)"
                        )
                    }

                    EditorCard("Appearance") {
                        GroupColorPicker(colorHex: $draft.colorHex)
                        GroupIconPicker(iconSystemName: $draft.iconSystemName,
                                        tintHex: draft.colorHex)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: 580)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Hosts")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondaryText)
            Spacer()
            Text(isNew ? "New group" : "Edit group")
                .font(.headline)
            Spacer()
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Delete group")
            } else {
                Image(systemName: "trash").opacity(0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Save", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
