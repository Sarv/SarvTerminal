import SwiftUI

/// Picker for `font-feature` OpenType tags.
///
/// The value is a comma-separated list of 4-letter tags (e.g. `calt, liga,
/// zero, ss01`). Users typically don't know these by heart, so we expose:
///
/// 1. A **trigger button** showing the current selection (or "Default").
/// 2. A popover with **toggle rows for common features** (ligatures, slashed
///    zero, fractions, stylistic alternates).
/// 3. A **text field for custom tags** (stylistic sets ss01–ss20, character
///    variants cv01–cv99, font-specific features).
struct FontFeaturePicker: View {
    @Binding var features: String

    @State private var isPresented: Bool = false
    @State private var customInput: String = ""

    /// Tags currently enabled, parsed from the bound string.
    private var tags: Set<String> {
        Set(features.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// Tags that aren't in the "common" presets, shown as custom chips.
    private var customTags: [String] {
        let known = Set(Self.commonFeatures.map { $0.tag })
        return tags.subtracting(known).sorted()
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            triggerLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    // MARK: - Trigger

    private var triggerLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam")
                .foregroundStyle(.secondary)
            Text(displayLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.controlColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private var displayLabel: String {
        if tags.isEmpty { return "Default" }
        return tags.sorted().joined(separator: ", ")
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OpenType Features")
                    .font(.headline)
                Spacer()
                if !tags.isEmpty {
                    Button("Reset") { features = "" }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.commonFeatures, id: \.tag) { feature in
                        toggleRow(feature)
                        Divider().padding(.leading, 14)
                    }

                    if !customTags.isEmpty {
                        Section {
                            ForEach(customTags, id: \.self) { tag in
                                customChipRow(tag)
                                Divider().padding(.leading, 14)
                            }
                        } header: {
                            Text("CUSTOM")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                    }
                }
            }
            .frame(maxHeight: 340)

            Divider()

            // Custom tag entry
            VStack(alignment: .leading, spacing: 4) {
                Text("Add custom tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("e.g. ss01, cv11, zero", text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addCustom)
                    Button("Add", action: addCustom)
                        .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
    }

    // MARK: - Rows

    private func toggleRow(_ feature: CommonFeature) -> some View {
        let on = tags.contains(feature.tag)
        return Toggle(isOn: Binding(
            get: { tags.contains(feature.tag) },
            set: { newValue in setTag(feature.tag, enabled: newValue) }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(feature.tag)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.label)
                    Text(feature.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(on ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func customChipRow(_ tag: String) -> some View {
        HStack {
            Text(tag)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Button {
                setTag(tag, enabled: false)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Mutation

    private func setTag(_ tag: String, enabled: Bool) {
        var t = tags
        let lowered = tag.lowercased()
        if enabled {
            t.insert(lowered)
        } else {
            t.remove(lowered)
        }
        features = t.sorted().joined(separator: ", ")
    }

    private func addCustom() {
        let raw = customInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return }
        // Split on comma/space in case user pasted multiple
        for token in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let cleaned = token.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                setTag(cleaned, enabled: true)
            }
        }
        customInput = ""
    }

    // MARK: - Catalog

    struct CommonFeature {
        let tag: String
        let label: String
        let detail: String
    }

    static let commonFeatures: [CommonFeature] = [
        .init(tag: "calt", label: "Contextual Alternates",
              detail: "Ligatures: -> ⇒, != ≠, etc. (font-dependent)"),
        .init(tag: "liga", label: "Standard Ligatures",
              detail: "Common combinations like fi, fl"),
        .init(tag: "dlig", label: "Discretionary Ligatures",
              detail: "Decorative; rarely needed in code"),
        .init(tag: "zero", label: "Slashed Zero",
              detail: "Distinguish 0 from O"),
        .init(tag: "frac", label: "Fractions",
              detail: "1/2 → ½"),
        .init(tag: "salt", label: "Stylistic Alternates",
              detail: "Alternate glyphs"),
        .init(tag: "ss01", label: "Stylistic Set 01",
              detail: "Font-specific variation"),
        .init(tag: "ss02", label: "Stylistic Set 02",
              detail: "Font-specific variation"),
        .init(tag: "ss03", label: "Stylistic Set 03",
              detail: "Font-specific variation"),
    ]
}
