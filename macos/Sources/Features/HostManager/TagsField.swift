import SwiftUI
import AppKit

/// Tag input with chip display + autocomplete suggestions sourced from
/// other saved hosts. Matches the Termius "Create Tag X" pattern.
struct TagsField: View {
    @Binding var tags: [String]
    let allKnownTags: [String]
    /// External focus tag for the editor's Tab/Shift+Tab chain.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @State private var input: String = ""
    @FocusState private var focused: Bool
    /// Keyboard highlight in the suggestion list (-1 = none, typing mode).
    @State private var highlighted: Int = -1
    /// Backspace-on-empty monitor, installed only while the input is focused.
    @State private var deleteMonitor: Any? = nil

    /// The rows currently shown in the suggestion list: matching known tags,
    /// plus a trailing "Create Tag …" entry for a genuinely new value. ONE
    /// source shared by rendering and keyboard navigation.
    private var listItems: [(label: String, isCreate: Bool)] {
        let q = input.trimmingCharacters(in: .whitespaces)
        var items = matchingSuggestions(query: q).map { (label: $0, isCreate: false) }
        let exists = allKnownTags.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
            || tags.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
        if !q.isEmpty && !exists {
            items.append((label: q, isCreate: true))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipsRow
            if focused {
                suggestionList
            }
        }
    }

    // MARK: - Chips + input

    private var chipsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 14))
                .foregroundStyle(.secondaryText)
                .frame(width: 18)

            // Flow layout-ish: chips then input. SwiftUI HStack will scroll;
            // for many tags we'd add wrapping, but for typical 1–4 tags this
            // is fine.
            ForEach(tags, id: \.self) { tag in
                TagChip(text: tag) { remove(tag) }
            }
            TextField(tags.isEmpty ? "Tags" : "", text: $input)
                .textFieldStyle(.plain)
                .focused($focused)
                .editorFocus(focus, field)
                .onSubmit { commit(input) }
                // ↑/↓ walk the suggestion list, Return picks the highlight
                // (falls through to onSubmit when nothing is highlighted).
                .listKeyNavigation(count: listItems.count, highlighted: $highlighted) { idx in
                    commit(listItems[idx].label)
                }
                .onChange(of: input) { _ in highlighted = -1 }
                // Backspace in an empty input removes the last chip, so tags
                // can be managed entirely from the keyboard. AppKit monitor —
                // the field editor consumes Backspace before SwiftUI key
                // handling ever sees it.
                .onChange(of: focused) { isFocused in
                    if isFocused { installDeleteMonitor() } else { removeDeleteMonitor() }
                }
                .onDisappear { removeDeleteMonitor() }
                .frame(minWidth: 80)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? Color.accentColor.opacity(0.7)
                                : Color.secondary.opacity(0.25),
                        lineWidth: focused ? 1.5 : 1)
        )
        .onHover { inside in
            if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = listItems
            ForEach(items.indices, id: \.self) { idx in
                suggestionRow(label: items[idx].label,
                              prefix: items[idx].isCreate ? "Create Tag" : nil,
                              highlighted: idx == highlighted) {
                    commit(items[idx].label)
                }
            }
            if items.isEmpty {
                Text(allKnownTags.isEmpty
                     ? "Type to add a tag"
                     : "Pick an existing tag or type a new one")
                    .font(.caption)
                    .foregroundStyle(.tertiaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func suggestionRow(label: String, prefix: String?, highlighted: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: prefix == nil ? "tag.fill" : "plus.circle")
                    .foregroundStyle(.secondaryText)
                    .font(.caption)
                if let prefix {
                    Text(prefix).foregroundStyle(.secondaryText)
                    Text(label).fontWeight(.medium)
                } else {
                    Text(label)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            // Keyboard highlight mirrors the hover treatment.
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlighted ? Color.secondary.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowHover(cornerRadius: 8)
    }

    // MARK: - Logic

    private func matchingSuggestions(query q: String) -> [String] {
        let q = q.lowercased()
        return allKnownTags
            .filter { !tags.contains($0) }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .prefix(6)
            .map { $0 }
    }

    private func commit(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        highlighted = -1
        guard !value.isEmpty, !tags.contains(value) else {
            input = ""; return
        }
        tags.append(value)
        input = ""
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    // MARK: - Backspace chip removal (AppKit monitor)

    private func installDeleteMonitor() {
        guard deleteMonitor == nil else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51,          // Backspace
                  input.isEmpty,
                  let last = tags.last else { return event }
            remove(last)
            return nil
        }
    }

    private func removeDeleteMonitor() {
        if let m = deleteMonitor {
            NSEvent.removeMonitor(m)
            deleteMonitor = nil
        }
    }
}

// MARK: - Chip

private struct TagChip: View {
    let text: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1.0 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.18))
        )
        .overlay(
            Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
    }
}
