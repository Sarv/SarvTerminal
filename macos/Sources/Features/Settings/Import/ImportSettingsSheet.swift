import SwiftUI
import AppKit

/// Guided importer: pick a source terminal, choose its config file, review what
/// auto-mapped (appearance) and confirm/skip each keybind, then apply.
struct ImportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var source: ImportSource = .ghostty
    @State private var imported: ImportedConfig?
    @State private var keybinds: [ImportedKeybind] = []
    @State private var errorText: String?
    @State private var result: TerminalImportApplier.Result?

    // Theme resolution (the source may name a theme that we match exactly,
    // approximately, or not at all).
    @State private var themeRaw: String?           // theme the source named
    @State private var themeCandidates: [String] = []
    @State private var selectedTheme: String = ""  // "" = use the default theme
    @State private var themeExact = false

    /// Ghostty actions offered in each keybind row's dropdown.
    private static let actionChoices = [
        "new_tab", "new_window", "close_surface",
        "new_split:right", "new_split:down", "goto_split:next", "goto_split:previous",
        "next_tab", "previous_tab", "toggle_fullscreen", "clear_screen",
        "copy_to_clipboard", "paste_from_clipboard",
        "increase_font_size:1", "decrease_font_size:1", "reset_font_size",
        "scroll_to_top", "scroll_to_bottom", "reload_config", "quit",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let result {
                    successView(result)
                } else if let imported {
                    reviewView(imported)
                } else {
                    pickView
                }
            }
        }
        .frame(width: 660, height: 580)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.secondaryText)
            Text("Import from another terminal")
                .font(.callout.weight(.semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondaryText)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Step 1 — pick source + file

    private var pickView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bring your colors, font, and keybindings over from another emulator. We only touch the terminal's appearance and shortcuts — your hosts, vaults, and sync stay untouched.")
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard(title: "Source") {
                settingsRow("Terminal") {
                    Picker("", selection: $source) {
                        ForEach(ImportSource.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 200, alignment: .leading)
                }
                SettingsDivider()
                settingsRow("Config file", alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.coverageNote)
                            .font(.caption).foregroundStyle(.secondaryText)
                        Button {
                            chooseFile()
                        } label: {
                            Label("Choose file…", systemImage: "folder")
                        }
                        if let errorText {
                            Text(errorText).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Step 2 — review

    @ViewBuilder
    private func reviewView(_ config: ImportedConfig) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                appearanceCard(config)
                keybindCard(config)
                if !config.warnings.isEmpty {
                    ForEach(config.warnings, id: \.self) { w in
                        Label(w, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) { reviewFooter }
    }

    private func appearanceCard(_ config: ImportedConfig) -> some View {
        SettingsCard(title: "Appearance — imported automatically") {
            VStack(alignment: .leading, spacing: 12) {
                if themeRaw != nil { themeRow }
                if config.appearanceSummary.isEmpty && themeRaw == nil {
                    Text("No appearance settings found in this file.")
                        .font(.callout).foregroundStyle(.secondaryText)
                } else {
                    ForEach(config.appearanceSummary, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                    if config.hasColors { swatches(config) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsMetrics.horizontalPadding)
        }
    }

    /// Theme resolution row: exact match (applied), similar matches (pick one),
    /// or no match (default).
    @ViewBuilder private var themeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if themeExact {
                Label("Theme: \(selectedTheme)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.primary)
                Text("Available in SarvTerminal — applied as-is.")
                    .font(.caption).foregroundStyle(.secondaryText)
            } else if !themeCandidates.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette").foregroundStyle(.secondaryText)
                    Text("Theme")
                    Picker("", selection: $selectedTheme) {
                        ForEach(themeCandidates, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Use default theme").tag("")
                    }
                    .labelsHidden().frame(width: 240)
                }
                Text("No exact match for “\(themeRaw ?? "")”. Pick the closest, or use the default.")
                    .font(.caption).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Theme: default", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.primary)
                Text("“\(themeRaw ?? "")” isn't available in SarvTerminal — using the default theme.")
                    .font(.caption).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatches(_ config: ImportedConfig) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(ColorSwatchPicker.color(fromHex: config.palette[i] ?? "#00000000") ?? Color.clear)
                    .frame(width: 15, height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.2)))
            }
        }
        .padding(.top, 4)
    }

    private func keybindCard(_ config: ImportedConfig) -> some View {
        SettingsCard(title: "Key bindings — review & confirm") {
            VStack(alignment: .leading, spacing: 0) {
                if keybinds.isEmpty {
                    Text("No key bindings in this source.")
                        .font(.callout).foregroundStyle(.secondaryText)
                        .padding(SettingsMetrics.horizontalPadding)
                } else {
                    ForEach(keybinds.indices, id: \.self) { i in
                        if i > 0 { SettingsDivider() }
                        keybindRow(i)
                    }
                }
            }
        }
    }

    private func keybindRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            // Their setting
            VStack(alignment: .leading, spacing: 2) {
                Text(keybinds[i].trigger)
                    .font(.system(.callout, design: .monospaced))
                Text(keybinds[i].sourceAction)
                    .font(.caption).foregroundStyle(.secondaryText).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)

            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiaryText)

            // Map to (editable)
            Picker("", selection: actionBinding(i)) {
                Text("Skip").tag("")
                ForEach(choices(for: keybinds[i]), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 230)

            if keybinds[i].include, keybinds[i].conflict {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(keybinds[i].conflictDetail ?? "already bound")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("This shortcut is already bound in SarvTerminal. Importing replaces it with the action shown — Skip to keep your current binding.")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    private var reviewFooter: some View {
        HStack {
            Button("Back") {
                imported = nil; keybinds = []; errorText = nil
                themeRaw = nil; themeCandidates = []; selectedTheme = ""; themeExact = false
            }
            Spacer()
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            Button(action: runImport) {
                Text("Import \(plannedCount) setting\(plannedCount == 1 ? "" : "s")")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plannedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Step 3 — success

    private func successView(_ r: TerminalImportApplier.Result) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Import complete")
                .font(.headline)
            Text("Applied \(r.appearanceCount) appearance setting\(r.appearanceCount == 1 ? "" : "s") and \(r.keybindCount) key binding\(r.keybindCount == 1 ? "" : "s"). It's live now.")
                .font(.callout).foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Logic

    private var plannedCount: Int {
        var n = imported?.appearanceSummary.count ?? 0
        if themeRaw != nil { n += 1 }   // theme applied, or reset to default
        n += keybinds.filter { $0.include && !($0.mappedAction ?? "").isEmpty }.count
        return n
    }

    private func choices(for kb: ImportedKeybind) -> [String] {
        var c = Self.actionChoices
        if let m = kb.mappedAction, !m.isEmpty, !c.contains(m) { c.insert(m, at: 0) }
        return c
    }

    private func actionBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { keybinds[i].mappedAction ?? "" },
            set: { newValue in
                keybinds[i].mappedAction = newValue.isEmpty ? nil : newValue
                keybinds[i].include = !newValue.isEmpty
            }
        )
    }

    private func chooseFile() {
        errorText = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your \(source.displayName) config file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var config = try TerminalImporter.parse(source: source, fileURL: url)
            resolveTheme(config.themeName)
            config.themeName = nil   // theme is applied from the sheet's selection
            if let f = config.fontFamily, !fontInstalled(f) {
                config.warnings.append("Font “\(f)” isn't installed on this Mac — the terminal falls back to its default until you install it. (The setting is still saved.)")
            }
            config.keybinds = TerminalImportApplier.markConflicts(in: config.keybinds)
            keybinds = config.keybinds
            imported = config
        } catch {
            errorText = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    /// Resolve the source's theme name against SarvTerminal's bundled themes:
    /// exact (normalized) match → apply it; near matches → offer them in a
    /// picker; nothing → fall back to the default. Drives the theme UI state.
    private func resolveTheme(_ raw: String?) {
        themeRaw = nil; themeCandidates = []; selectedTheme = ""; themeExact = false
        guard let raw, !raw.isEmpty else { return }
        themeRaw = raw

        let all = ThemePicker.discover().map(\.name)
        let key = normalizeName(raw)

        if let exact = all.first(where: { normalizeName($0) == key }) {
            themeExact = true
            selectedTheme = exact
            themeCandidates = [exact]
            return
        }
        // Similar: normalized substring (either direction) or a shared word.
        let tokens = wordTokens(raw)
        let similar = all.filter { name in
            let nk = normalizeName(name)
            if key.count >= 3, nk.contains(key) || key.contains(nk) { return true }
            return !tokens.isDisjoint(with: wordTokens(name))
        }
        .sorted { lhs, rhs in
            let lp = normalizeName(lhs).hasPrefix(key), rp = normalizeName(rhs).hasPrefix(key)
            if lp != rp { return lp }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        themeCandidates = Array(similar.prefix(12))
        selectedTheme = themeCandidates.first ?? ""   // "" → default when none
    }

    private func normalizeName(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private func wordTokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    private func fontInstalled(_ family: String) -> Bool {
        if NSFontManager.shared.availableFontFamilies.contains(family) { return true }
        return NSFont(name: family, size: 12) != nil
    }

    private func runImport() {
        guard var config = imported else { return }
        errorText = nil
        if themeRaw != nil {
            if selectedTheme.isEmpty {
                config.resetColorsToDefault = true
                config.themeName = nil
            } else {
                config.themeName = selectedTheme
                config.resetColorsToDefault = false
            }
        }
        do {
            result = try TerminalImportApplier.apply(config, keybinds: keybinds)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
