import SwiftUI

/// Picker for choosing a parent group. Renders as a full-width pill row,
/// opens a popover with the full group tree indented by depth.
///
/// - `excludedID`: when editing a group, pass the group's own ID — it (and
///   its descendants) are dimmed/disabled to prevent creating a cycle.
struct ParentGroupPicker: View {
    @Binding var groupID: UUID?
    var excludedID: UUID? = nil
    var placeholder: String = "Parent Group"

    @ObservedObject private var store = HostGroupsStore.shared
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            row
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    // MARK: - Trigger row

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if let groupID, !displayPath(for: groupID).isEmpty {
                Text(displayPath(for: groupID))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Popover content

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                Text("Parent Group").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    optionRow(
                        icon: "tray",
                        label: "No group (root)",
                        depth: 0,
                        isSelected: groupID == nil,
                        disabled: false
                    ) {
                        groupID = nil
                        isPresented = false
                    }
                    Divider().padding(.leading, 12)

                    let entries = menuEntries()
                    if entries.isEmpty {
                        Text("No groups yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(entries.indices, id: \.self) { i in
                            let entry = entries[i]
                            optionRow(
                                icon: "folder",
                                label: entry.name,
                                depth: entry.depth,
                                isSelected: groupID == entry.id,
                                disabled: entry.disabled
                            ) {
                                guard !entry.disabled else { return }
                                groupID = entry.id
                                isPresented = false
                            }
                            if i < entries.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 320)
        }
        .frame(width: 320)
    }

    private func optionRow(
        icon: String,
        label: String,
        depth: Int,
        isSelected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Real indentation per depth — child rows visibly nest under
                // their parent. A leading vertical hairline reinforces the
                // hierarchy beyond depth 0.
                if depth > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<depth, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1)
                                .padding(.horizontal, 8)
                        }
                    }
                    .frame(height: 18)
                }
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(label)
                    .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Helpers

    private struct Entry {
        let id: UUID
        let name: String
        let depth: Int
        let disabled: Bool
    }

    private func menuEntries() -> [Entry] {
        let excludedSet: Set<UUID> = {
            guard let excludedID else { return [] }
            return store.descendants(of: excludedID).union([excludedID])
        }()
        return store.flatTree().map { (g, depth) in
            Entry(
                id: g.id,
                name: g.displayName,
                depth: depth,
                disabled: excludedSet.contains(g.id)
            )
        }
    }

    private func displayPath(for id: UUID) -> String {
        store.path(for: id)
    }
}
