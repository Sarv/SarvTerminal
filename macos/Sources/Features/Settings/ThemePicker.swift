import SwiftUI

/// Theme picker that discovers all available themes (built-in + user) and
/// shows them with a small **color preview** per row so you can see what the
/// theme actually looks like before selecting.
///
/// Discovery:
/// - Built-in: `<bundle resources>/ghostty/themes/*`
/// - User:     `$XDG_CONFIG_HOME/ghostty/themes/*` (or `~/.config/ghostty/themes/*`)
///
/// Previews are parsed lazily on first popover open (async — UI stays
/// responsive) and cached for the lifetime of the picker instance.
struct ThemePicker: View {
    @Binding var themeName: String
    /// External focus tag for the host editor's Tab/Shift+Tab chain — when
    /// the chain lands here, Return/Space opens the popover.
    var focus: FocusState<HostEditorFocusField?>.Binding? = nil
    var field: HostEditorFocusField? = nil

    @State private var isPresented: Bool = false
    @State private var search: String = ""
    @State private var themes: [ThemeEntry] = []
    @State private var previews: [String: ThemePreview] = [:]
    @State private var didLoad: Bool = false
    /// Keyboard highlight in the popover list (0 = default row, 1… = themes).
    @State private var highlighted: Int = -1
    @FocusState private var searchFocused: Bool

    /// The editor's focus chain points at this picker.
    private var isChainFocused: Bool {
        field != nil && focus?.wrappedValue == field
    }

    var body: some View {
        Button {
            ensureLoaded()
            isPresented = true
        } label: {
            triggerLabel
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .focusable()
        .editorFocus(focus, field)
        .modifier(ActivateOnKeyPress {
            ensureLoaded()
            isPresented = true
        })
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        // Preload themes + previews when the picker first appears, so the
        // trigger swatch is populated even before the user opens the popover.
        .task {
            ensureLoaded()
        }
    }

    // MARK: - Trigger

    private var triggerLabel: some View {
        HStack(spacing: 8) {
            // Show the theme's own background+foreground preview if loaded.
            if !themeName.isEmpty, let preview = previews[themeName] {
                themePreviewSwatch(preview: preview, big: false)
            } else {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondaryText)
                    .frame(width: 36, height: 22)
            }
            Text(themeName.isEmpty ? "Default (no theme)" : themeName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.controlColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isChainFocused ? Color.accentColor.opacity(0.7)
                                       : Color.secondary.opacity(0.25),
                        lineWidth: isChainFocused ? 1.5 : 1)
        )
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondaryText)
                TextField("Search themes…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // ↑/↓ walk the list, Return picks the highlighted theme.
                    .listKeyNavigation(count: 1 + filteredThemes.count,
                                       highlighted: $highlighted) { pickRow($0) }
                    .onChange(of: search) { _ in highlighted = -1 }
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        defaultRow
                            .id("::default::")
                        if !themes.isEmpty { Divider() }
                        ForEach(Array(filteredThemes.enumerated()), id: \.element.name) { idx, entry in
                            themeRow(entry, isHighlighted: highlighted == idx + 1)
                                .id(entry.name)
                        }
                        if filteredThemes.isEmpty && !themes.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                        }
                    }
                }
                // Land on the CURRENT theme when the dropdown opens — with 500+
                // themes the selection is otherwise lost below the fold. Theme
                // discovery is async, so also fire when the list populates.
                .onAppear {
                    searchFocused = true
                    guard !themeName.isEmpty else { return }
                    proxy.scrollTo(themeName, anchor: .center)
                }
                .onChange(of: highlighted) { idx in
                    guard idx >= 0 else { return }
                    proxy.scrollTo(idx == 0 ? "::default::" : filteredThemes[idx - 1].name)
                }
                .onChange(of: themes.count) { _ in
                    guard !themeName.isEmpty else { return }
                    DispatchQueue.main.async { proxy.scrollTo(themeName, anchor: .center) }
                }
            }
            .frame(maxHeight: 400)

            Divider()

            HStack {
                Text("\(themes.count) themes")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                Spacer()
                if previews.isEmpty && !themes.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading previews…")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
    }

    /// Keyboard pick: row 0 = "Default (no theme)", rows 1… = filtered themes.
    private func pickRow(_ idx: Int) {
        if idx == 0 {
            themeName = ""
        } else if filteredThemes.indices.contains(idx - 1) {
            themeName = filteredThemes[idx - 1].name
        } else {
            return
        }
        isPresented = false
    }

    // MARK: - Rows

    private var defaultRow: some View {
        let isSelected = themeName.isEmpty
        return Button {
            themeName = ""
            isPresented = false
        } label: {
            HStack {
                Image(systemName: "circle.dashed")
                    .frame(width: 32, height: 22)
                    .foregroundStyle(.secondaryText)
                Text("Default (no theme)")
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18)
                        : highlighted == 0 ? Color.secondary.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .listRowHover(cornerRadius: 0)
        }
        .buttonStyle(.plain)
    }

    private func themeRow(_ entry: ThemeEntry, isHighlighted: Bool = false) -> some View {
        let isSelected = themeName == entry.name
        let preview = previews[entry.name]
        return Button {
            themeName = entry.name
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                if let preview {
                    themePreviewSwatch(preview: preview, big: true)
                } else {
                    // Placeholder while previews load.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 80, height: 22)
                }
                Text(entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18)
                        : isHighlighted ? Color.secondary.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .listRowHover(cornerRadius: 0)
        }
        .buttonStyle(.plain)
    }

    /// One-row preview: a rectangle of the theme's background color with
    /// the foreground color painted as "Aa" inside it, followed by 4 small
    /// accent swatches from the palette.
    private func themePreviewSwatch(preview: ThemePreview, big: Bool) -> some View {
        let bg = preview.background ?? Color.gray
        let fg = preview.foreground ?? Color.white

        return HStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
                Text("Aa")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fg)
            }
            .frame(width: 36, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            ForEach([1, 2, 4, 5], id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(preview.palette[idx] ?? Color.clear)
                    .frame(width: 10, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )
            }
        }
        .opacity(big ? 1.0 : 0.95)
    }

    private var filteredThemes: [ThemeEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return themes }
        return themes.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Discovery + preview parsing

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        // Discovery lists a few hundred bundled theme files — keep it (and the
        // preview parsing) off the main thread so views embedding this picker
        // (e.g. the host editor sidebar) open without a hitch.
        Task.detached(priority: .userInitiated) {
            let entries = Self.discover()
            await MainActor.run {
                self.themes = entries
            }
            let parsed = Self.parseAll(themes: entries)
            await MainActor.run {
                self.previews = parsed
            }
        }
    }

    private static func parseAll(themes: [ThemeEntry]) -> [String: ThemePreview] {
        var out: [String: ThemePreview] = [:]
        for entry in themes {
            if let preview = parsePreview(at: entry.url) {
                out[entry.name] = preview
            }
        }
        return out
    }

    static func discover() -> [ThemeEntry] {
        var byName: [String: ThemeEntry] = [:]

        // Bundled
        if let resourcePath = Bundle.main.resourcePath {
            scan(
                URL(fileURLWithPath: resourcePath)
                    .appendingPathComponent("ghostty/themes"),
                into: &byName
            )
        }
        // User (user overrides built-in if same name)
        let env = ProcessInfo.processInfo.environment
        let baseDir: URL = {
            if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
                return URL(fileURLWithPath: xdg)
            }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        }()
        scan(baseDir.appendingPathComponent("ghostty/themes"), into: &byName)

        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func scan(_ dir: URL, into out: inout [String: ThemeEntry]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let name = entry.lastPathComponent
            out[name] = ThemeEntry(name: name, url: entry)
        }
    }

    /// The theme currently set in the config file — the SINGLE source of truth
    /// for "which theme is active". Use this everywhere the current theme is
    /// shown (Settings ▸ Appearance, the sidebar Themes tab, the importer) so no
    /// view can drift out of sync. Reads the file fresh each call. "" = default
    /// (no theme).
    static func currentThemeName() -> String {
        Ghostty.Config.rawConfigFileValue("theme") ?? ""
    }

    /// Parse a Ghostty theme file for the few colors we need to preview.
    /// We only handle hex literals; named colors (rare in shipped themes)
    /// are skipped — that row gets no swatch.
    static func parsePreview(at url: URL) -> ThemePreview? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var bg: Color?
        var fg: Color?
        var palette: [Int: Color] = [:]
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background":
                bg = ColorSwatchPicker.color(fromHex: value)
            case "foreground":
                fg = ColorSwatchPicker.color(fromHex: value)
            case "palette":
                // "<index>=<hex>"
                if let innerEq = value.firstIndex(of: "=") {
                    let idxStr = value[..<innerEq].trimmingCharacters(in: .whitespaces)
                    let colorStr = String(value[value.index(after: innerEq)...]).trimmingCharacters(in: .whitespaces)
                    if let idx = Int(idxStr), let c = ColorSwatchPicker.color(fromHex: colorStr) {
                        palette[idx] = c
                    }
                }
            default:
                continue
            }
        }
        // Reject if we got nothing useful.
        if bg == nil && fg == nil && palette.isEmpty { return nil }
        return ThemePreview(background: bg, foreground: fg, palette: palette)
    }
}

// MARK: - Types

struct ThemeEntry: Hashable {
    let name: String
    let url: URL
}

struct ThemePreview {
    let background: Color?
    let foreground: Color?
    /// ANSI palette indices 0–15.
    let palette: [Int: Color]
}

