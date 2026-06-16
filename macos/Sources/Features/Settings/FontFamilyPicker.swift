import SwiftUI
import AppKit

/// Picker for `font-family`. Discovers installed system fonts filtered to
/// monospaced (fixed-pitch) families and shows them in a searchable popover
/// — each row previews the font in its own face.
struct FontFamilyPicker: View {
    @Binding var family: String

    @State private var isPresented: Bool = false
    @State private var search: String = ""
    @State private var families: [String] = []
    @State private var didLoad: Bool = false

    var body: some View {
        Button {
            ensureLoaded()
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
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
            Text(family.isEmpty ? "System default" : family)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(family.isEmpty ? .body : .custom(family, size: 13))
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

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search monospaced fonts…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fontRow(name: "", display: "System default", previewFont: .system(.body, design: .monospaced))
                    if !families.isEmpty { Divider() }
                    ForEach(filteredFamilies, id: \.self) { name in
                        fontRow(name: name, display: name, previewFont: .custom(name, size: 13))
                    }
                    if filteredFamilies.isEmpty && !families.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()

            HStack {
                Text("\(families.count) monospaced families")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
    }

    private func fontRow(name: String, display: String, previewFont: Font) -> some View {
        let isSelected = family == name
        return Button {
            family = name
            isPresented = false
        } label: {
            HStack {
                Text(display)
                    .font(previewFont)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredFamilies: [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return families }
        return families.filter { $0.lowercased().contains(q) }
    }

    // MARK: - Discovery

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        families = Self.discover()
    }

    /// All monospaced font families installed on the system. Uses
    /// `NSFontManager` to filter by `fixedPitchFontMask`.
    static func discover() -> [String] {
        let manager = NSFontManager.shared
        let monospaceTrait = NSFontTraitMask.fixedPitchFontMask
        var result: [String] = []
        for family in manager.availableFontFamilies {
            // Hide internal/private fonts that start with "."
            if family.hasPrefix(".") { continue }
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            // members is [[Any]]; element 3 is traits NSNumber per AppKit docs.
            let isMonospace = members.contains { member in
                guard member.count > 3, let traitNum = member[3] as? NSNumber else { return false }
                let traits = NSFontTraitMask(rawValue: UInt(traitNum.uintValue))
                return traits.contains(monospaceTrait)
            }
            if isMonospace {
                result.append(family)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
