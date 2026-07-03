import SwiftUI
import AppKit

/// Termius-style right command sidebar for the tabbed terminal window. Four
/// tabs — Search (⌘F in the active view), Snippets, History, Themes/Font — that
/// surface EXISTING data (SnippetsStore, ShellHistory, Ghostty themes/font) and
/// Run/Paste into the active terminal via VaultsTabsModel. No new business logic.
struct VaultsCommandSidebar: View {
    enum Tab: String, CaseIterable, Identifiable {
        case snippets, history, theme
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .snippets: return "curlybraces"
            case .history:  return "clock"
            case .theme:    return "paintpalette"
            }
        }
        var title: String {
            switch self {
            case .snippets: return "Snippets"
            case .history:  return "Shell history"
            case .theme:    return "Themes & font"
            }
        }
    }

    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            switcher
            Divider()
            Group {
                switch tab {
                case .snippets: SnippetsTab()
                case .history:  HistoryTab()
                case .theme:    ThemeTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
    }

    private var switcher: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(tab == t ? Color.white : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tab == t ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared row (pin + hover-revealed actions)

/// A command row: pin toggle, command text, and hover-revealed Run/Paste (and,
/// for history, "add to snippet"). Reused by the Snippets and History tabs.
private struct CommandRow: View {
    /// Main line. For snippets this is the name; for history it's the command.
    let primary: String
    /// Second line (snippets show the command here). nil = single-line row.
    var secondary: String? = nil
    /// Render the primary line in monospace (history rows).
    var monoPrimary: Bool = false
    /// The text Run/Paste send.
    let command: String
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    /// History only — opens the "name this snippet" prompt.
    var onAddToSnippet: (() -> Void)? = nil

    @ObservedObject private var tabs = VaultsTabsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin to top")
                .opacity(isPinned || hovering ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(monoPrimary
                          ? .system(size: 12, design: .monospaced)
                          : .system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, secondary == nil ? 7 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover only tints the background — actions float in a trailing overlay
        // so the row never changes size.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 6) {
                    if let onAddToSnippet {
                        Button(action: onAddToSnippet) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.22)))
                        }
                        .buttonStyle(.plain)
                        .help("Add to snippet")
                    }
                    pill("Run", tint: .accentColor) { tabs.runInTargetTerminal(command) }
                    pill("Paste", tint: .secondary) { tabs.pasteToTargetTerminal(command) }
                }
                .padding(.trailing, 10)
                .padding(.leading, 28)
                .frame(maxHeight: .infinity)
                // Opaque backing (with a soft leading fade) so the command text
                // behind doesn't bleed through the buttons.
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: Color(NSColor.windowBackgroundColor).opacity(0), location: 0),
                            .init(color: Color(NSColor.windowBackgroundColor), location: 0.45),
                            .init(color: Color(NSColor.windowBackgroundColor), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func pill(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        let isAccent = tint == .accentColor
        return Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isAccent ? Color.accentColor : Color.primary.opacity(0.22)))
                .foregroundStyle(isAccent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!tabs.hasActiveTerminal)
        .opacity(tabs.hasActiveTerminal ? 1 : 0.4)
        .help("\(label) in the active terminal")
    }
}

private struct SidebarSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

/// Inline name/command editor used for "New Snippet" and history "Add to snippet".
/// Reuses SnippetsStore.upsert. `fixedCommand` (history) shows the command read-only.
private struct SnippetEditorInline: View {
    let heading: String
    var fixedCommand: String? = nil
    let onDone: () -> Void

    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { onDone() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text(heading).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(effectiveCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
            if let fixedCommand {
                Text(fixedCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            } else {
                TextEditor(text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            Spacer()
        }
        .padding(12)
    }

    private var effectiveCommand: String { fixedCommand ?? command }

    private func save() {
        let now = Date()
        SnippetsStore.shared.upsert(Snippet(id: UUID(), name: name, command: effectiveCommand, createdAt: now, updatedAt: now))
        onDone()
    }
}

// MARK: - Snippets tab

private struct SnippetsTab: View {
    @ObservedObject private var store = SnippetsStore.shared
    @State private var query = ""
    @State private var creating = false
    /// Newest-first by default; the sort button flips it.
    @State private var sortDescending = true

    /// Pinned first, then by date added (newest first unless the sort is flipped).
    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = store.snippets.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return sortDescending ? a.createdAt > b.createdAt : a.createdAt < b.createdAt
        }
        guard !q.isEmpty else { return all }
        return all.filter { SearchMatcher.matches(q, in: [$0.name, $0.command]) }
    }

    var body: some View {
        if creating {
            SnippetEditorInline(heading: "New Snippet") { creating = false }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button { creating = true } label: {
                        Label("New Snippet", systemImage: "curlybraces")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                    .help("Create a new snippet")
                    Spacer()
                    Button { sortDescending.toggle() } label: {
                        Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(sortDescending ? "Sort: newest first (descending)" : "Sort: oldest first (ascending)")
                }
                .padding(.horizontal, 12).padding(.top, 10)

                SidebarSearchField(placeholder: "Search snippets", text: $query)

                if filtered.isEmpty {
                    emptyState(query.isEmpty ? "No snippets yet." : "No matching snippets.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { s in
                                CommandRow(
                                    primary: s.displayName,
                                    secondary: s.command,
                                    command: s.command,
                                    isPinned: s.pinned,
                                    onTogglePin: {
                                        var copy = s; copy.pinned.toggle(); copy.updatedAt = Date()
                                        store.upsert(copy)
                                    })
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

// MARK: - History tab

private struct HistoryTab: View {
    @ObservedObject private var pins = PinnedHistoryStore.shared
    @State private var query = ""
    @State private var recent: [String] = []
    /// Command currently being named for "Add to snippet"; nil = list mode.
    @State private var naming: String?

    /// Total shown; pinned are exempt so only the rest count toward this cap.
    private let cap = 100

    private var pinnedRows: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pins.pinned }
        return pins.pinned.filter { SearchMatcher.matches(q, in: [$0]) }
    }

    private var recentRows: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Pinned commands are exempt from the cap; the rest fill up to `cap`.
        let nonPinned = recent.filter { !pins.isPinned($0) }
        let capped = Array(nonPinned.prefix(max(0, cap - pins.pinned.count)))
        guard !q.isEmpty else { return capped }
        return capped.filter { SearchMatcher.matches(q, in: [$0]) }
    }

    var body: some View {
        if let cmd = naming {
            SnippetEditorInline(heading: "Add to snippet", fixedCommand: cmd) { naming = nil }
        } else {
            VStack(spacing: 0) {
                SidebarSearchField(placeholder: "Search history", text: $query)
                if pinnedRows.isEmpty && recentRows.isEmpty {
                    emptyState(recent.isEmpty ? "No shell history found." : "No matching commands.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // Distinct identities for pinned vs recent so toggling
                            // a pin rebuilds the row (and its pin icon) cleanly
                            // instead of reusing the moved instance.
                            ForEach(pinnedRows, id: \.self) { cmd in row(cmd).id("pin-\(cmd)") }
                            ForEach(recentRows, id: \.self) { cmd in row(cmd).id("rec-\(cmd)") }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                }
            }
            .onAppear { recent = ShellHistory.recent() }
        }
    }

    private func row(_ cmd: String) -> some View {
        CommandRow(
            primary: cmd,
            monoPrimary: true,
            command: cmd,
            isPinned: pins.isPinned(cmd),
            onTogglePin: { pins.toggle(cmd) },
            onAddToSnippet: { naming = cmd })
    }
}

// MARK: - Placeholders (pass 2: Themes/Font + Search)

// MARK: - Themes & Font tab

/// Reads/writes the global theme + font by editing the Ghostty config file and
/// reloading — the SAME mechanism the Settings window uses (ConfigFileEditor +
/// ghostty.reloadConfig), so changes apply live to every open terminal.
@MainActor
private final class SidebarAppearance: ObservableObject {
    @Published var themeName = ""
    @Published var fontFamily = ""
    @Published var fontSize: Double = 13

    private var token: NSObjectProtocol?

    init() {
        reload()
        token = NotificationCenter.default.addObserver(
            forName: .sarvConfigDidCommit, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    private var config: Ghostty.Config? { (NSApp.delegate as? AppDelegate)?.ghostty.config }

    func reload() {
        themeName = config?.themeName ?? ""
        fontFamily = config?.fontFamily ?? ""
        fontSize = config?.fontSize ?? 13
    }

    func apply(theme: String) {
        themeName = theme
        commit { editor in
            if theme.isEmpty { editor.remove("theme") } else { editor.set("theme", theme) }
            // Selecting a theme resets the background so the theme shows cleanly:
            // opaque, with the theme's own background (no leftover translucency /
            // color override). Adding a background image later re-enables the
            // translucent look via Appearance settings.
            editor.set("background-opacity", "1")
            editor.remove("background")
            // Keep the window CHROME on the system appearance so a light terminal
            // theme doesn't flip the toolbar to white and hide our light icons.
            editor.set("window-theme", "system")
        }
    }
    func setFontFamily(_ family: String) {
        fontFamily = family
        commit { family.isEmpty ? $0.remove("font-family") : $0.set("font-family", family) }
    }
    func nudgeFontSize(_ delta: Double) {
        fontSize = min(64, max(6, fontSize + delta))
        commit { $0.set("font-size", String(format: "%g", fontSize)) }
    }

    private func commit(_ mutate: (ConfigFileEditor) -> Void) {
        guard let editor = try? ConfigFileEditor() else { return }
        mutate(editor)
        try? editor.commit()
        // App-level reload re-derives each open surface's config (background
        // color + opacity + font) and repaints live terminals.
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        NotificationCenter.default.post(name: .sarvConfigDidCommit, object: nil)
    }
}

private struct ThemeTab: View {
    @StateObject private var appearance = SidebarAppearance()
    @State private var themes: [ThemeEntry] = []
    @State private var previews: [String: ThemePreview] = [:]
    @State private var query = ""
    @State private var fontExpanded = false

    private var filtered: [ThemeEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return themes }
        return themes.filter { SearchMatcher.matches(q, in: [$0.name]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            fontSection
            Divider()
            SidebarSearchField(placeholder: "Search themes", text: $query)
            ScrollView {
                LazyVStack(spacing: 2) {
                    themeRow(name: "", preview: nil, isDefault: true)
                    ForEach(filtered, id: \.name) { entry in
                        themeRow(name: entry.name, preview: previews[entry.name], isDefault: false)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Font (collapsible)

    private var fontSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { fontExpanded.toggle() }
            } label: {
                HStack {
                    Text("Font").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: fontExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 10)

            if fontExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    FontFamilyPicker(family: Binding(
                        get: { appearance.fontFamily },
                        set: { appearance.setFontFamily($0) }))
                    HStack {
                        Text("Text Size").font(.system(size: 12))
                        Spacer()
                        stepper("minus") { appearance.nudgeFontSize(-1) }
                        Text("\(Int(appearance.fontSize.rounded()))")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 26)
                        stepper("plus") { appearance.nudgeFontSize(1) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
    }

    private func stepper(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Theme rows

    private func themeRow(name: String, preview: ThemePreview?, isDefault: Bool) -> some View {
        let selected = appearance.themeName == name
        return Button {
            appearance.apply(theme: name)
        } label: {
            HStack(spacing: 10) {
                if isDefault {
                    Image(systemName: "circle.dashed")
                        .frame(width: 34, height: 22).foregroundStyle(.secondary)
                } else {
                    ThemeSwatch(preview: preview)
                }
                Text(isDefault ? "Default (no theme)" : name)
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard themes.isEmpty else { return }
        let entries = ThemePicker.discover()
        themes = entries
        Task.detached(priority: .userInitiated) {
            var parsed: [String: ThemePreview] = [:]
            for e in entries { if let p = ThemePicker.parsePreview(at: e.url) { parsed[e.name] = p } }
            await MainActor.run { self.previews = parsed }
        }
    }
}

/// Termius-style mini-terminal thumbnail: the theme's background with a few
/// rows of colored "text" bars (using the palette + foreground) and a cursor,
/// so each theme reads at a glance.
private struct ThemeSwatch: View {
    let preview: ThemePreview?

    var body: some View {
        let bg = preview?.background ?? Color.black
        let fg = preview?.foreground ?? Color.white
        func c(_ i: Int, _ fallback: Color) -> Color { preview?.palette[i] ?? fallback }

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(bg)
            .frame(width: 48, height: 34)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) { bar(c(2, .green), 9); bar(fg, 18) }       // prompt + command
                    HStack(spacing: 3) { bar(c(4, .blue), 7); bar(c(6, .cyan), 14) }
                    HStack(spacing: 3) {
                        bar(c(3, .yellow), 6); bar(fg.opacity(0.8), 9)
                        RoundedRectangle(cornerRadius: 1).fill(fg).frame(width: 4, height: 5) // cursor
                    }
                }
                .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func bar(_ color: Color, _ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: width, height: 3)
    }
}

@ViewBuilder
private func emptyState(_ text: String) -> some View {
    VStack {
        Spacer()
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
