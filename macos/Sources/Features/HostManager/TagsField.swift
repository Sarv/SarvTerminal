import SwiftUI

/// Tag input with chip display + autocomplete suggestions sourced from
/// other saved hosts. Matches the Termius "Create Tag X" pattern.
struct TagsField: View {
    @Binding var tags: [String]
    let allKnownTags: [String]

    @State private var input: String = ""
    @FocusState private var focused: Bool

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
                .foregroundStyle(.secondary)
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
                .onSubmit { commit(input) }
                .onChange(of: input) { _ in /* triggers suggestion redraw */ }
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
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let q = input.trimmingCharacters(in: .whitespaces)
            let suggestions = matchingSuggestions(query: q)

            if !suggestions.isEmpty {
                ForEach(suggestions, id: \.self) { tag in
                    suggestionRow(label: tag, prefix: nil) { commit(tag) }
                }
            }
            if !q.isEmpty && !tags.contains(q) {
                suggestionRow(label: q, prefix: "Create Tag") { commit(q) }
            } else if suggestions.isEmpty && q.isEmpty {
                Text(allKnownTags.isEmpty
                     ? "Type to add a tag"
                     : "Pick an existing tag or type a new one")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    private func suggestionRow(label: String, prefix: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: prefix == nil ? "tag.fill" : "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if let prefix {
                    Text(prefix).foregroundStyle(.secondary)
                    Text(label).fontWeight(.medium)
                } else {
                    Text(label)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        guard !value.isEmpty, !tags.contains(value) else {
            input = ""; return
        }
        tags.append(value)
        input = ""
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
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
