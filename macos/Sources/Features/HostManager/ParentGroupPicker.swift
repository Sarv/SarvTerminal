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
    /// External focus tag for the editor's Tab/Shift+Tab chain — when the
    /// chain lands here, Return/Space opens the popover.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @ObservedObject private var store = HostGroupsStore.shared
    @State private var isPresented = false
    /// Keyboard highlight in the popover list (0 = root row, 1… = groups).
    @State private var highlighted: Int = -1
    @FocusState private var listFocused: Bool

    /// The editor's focus chain points at this picker.
    private var isChainFocused: Bool {
        field != nil && focus?.wrappedValue == field
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            row
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .focusable()
        .editorFocus(focus, field)
        .modifier(ActivateOnKeyPress { isPresented = true })
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    // MARK: - Trigger row

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14))
                .foregroundStyle(.secondaryText)
                .frame(width: 18)
            if let groupID, !displayPath(for: groupID).isEmpty {
                Text(displayPath(for: groupID))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(placeholder)
                    .foregroundStyle(.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiaryText)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isChainFocused ? Color.accentColor.opacity(0.7)
                                       : Color.secondary.opacity(0.22),
                        lineWidth: isChainFocused ? 1.5 : 1)
        )
    }

    // MARK: - Popover content

    private var popoverContent: some View {
        let entries = menuEntries()
        // Row 0 = "No group (root)", rows 1… = the group tree.
        let rowCount = 1 + entries.count
        func pick(_ idx: Int) {
            if idx == 0 {
                groupID = nil
            } else {
                let entry = entries[idx - 1]
                guard !entry.disabled else { return }
                groupID = entry.id
            }
            isPresented = false
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondaryText)
                Text("Parent Group").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        optionRow(
                            icon: "tray",
                            label: "No group (root)",
                            depth: 0,
                            isSelected: groupID == nil,
                            disabled: false,
                            highlighted: highlighted == 0
                        ) { pick(0) }
                        .id(0)
                        Divider().padding(.leading, 12)

                        if entries.isEmpty {
                            Text("No groups yet")
                                .font(.callout)
                                .foregroundStyle(.secondaryText)
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
                                    disabled: entry.disabled,
                                    highlighted: highlighted == i + 1
                                ) { pick(i + 1) }
                                .id(i + 1)
                                if i < entries.count - 1 {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 320)
                // Keyboard: ↑/↓ move (skipping disabled rows), Return picks,
                // Esc closes (native popover behavior).
                .focusable()
                .focused($listFocused)
                .listKeyNavigation(
                    count: rowCount,
                    highlighted: $highlighted,
                    isSelectable: { $0 == 0 || !entries[$0 - 1].disabled },
                    onPick: pick
                )
                .onChange(of: highlighted) { idx in
                    guard idx >= 0 else { return }
                    proxy.scrollTo(idx)
                }
                .onAppear {
                    listFocused = true
                    // Start the highlight on the current selection.
                    if let groupID, let i = entries.firstIndex(where: { $0.id == groupID }) {
                        highlighted = i + 1
                        DispatchQueue.main.async { proxy.scrollTo(i + 1, anchor: .center) }
                    } else {
                        highlighted = 0
                    }
                }
            }
        }
        .frame(width: 320)
    }

    private func optionRow(
        icon: String,
        label: String,
        depth: Int,
        isSelected: Bool,
        disabled: Bool,
        highlighted: Bool = false,
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
                    .foregroundStyle(.secondaryText)
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
            // Keyboard highlight mirrors the hover treatment.
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted ? Color.secondary.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .listRowHover(isEnabled: !disabled)
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
