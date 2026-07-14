import SwiftUI

/// Compact button that, when clicked, opens a popover rendering a mock
/// terminal session using the selected theme's colors. Lets the user
/// see what the theme actually looks like in practice — prompt, git
/// status, log levels, paths, success/failure markers — without
/// committing to apply it.
struct ThemePreviewButton: View {
    let themeName: String

    @State private var isPresented: Bool = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Preview", systemImage: "eye")
        }
        .controlSize(.regular)
        .disabled(themeName.isEmpty)
        .help("Preview \(themeName.isEmpty ? "the theme" : themeName) with sample terminal output")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            // Sheet owns the loading lifecycle — guarantees fresh data on
            // every popover open without any state-race between button
            // and popover content.
            ThemePreviewSheet(themeName: themeName)
        }
    }
}

/// Resolve a theme file URL from a theme name. Looks in the user themes
/// directory first (overrides built-in), then the bundled themes.
enum ThemeFileResolver {
    static func candidateURLs(for name: String) -> [URL] {
        var urls: [URL] = []
        // Our ISOLATED user themes dir (`sarvterminal/themes`), not `ghostty/themes`.
        urls.append(AppPaths.terminalThemesDir.appendingPathComponent(name))
        if let resourcePath = Bundle.main.resourcePath {
            urls.append(URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("ghostty/themes")
                .appendingPathComponent(name))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Popover content: a mock terminal session styled with the theme's
/// background, foreground, and ANSI palette colors. Content is a hand-
/// curated sample that exercises common color slots: shell prompt, git
/// status, log levels, paths, status markers.
struct ThemePreviewSheet: View {
    let themeName: String

    @State private var preview: ThemePreview?
    @State private var loadState: LoadState = .loading
    @Environment(\.dismiss) private var dismiss

    enum LoadState {
        case loading
        case loaded
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch loadState {
            case .loading:
                loadingView
            case .loaded:
                if let preview {
                    mockTerminal(preview)
                } else {
                    noPreviewView
                }
            case .failed:
                noPreviewView
            }
        }
        .frame(width: 620)
        .task(id: themeName) {
            loadState = .loading
            preview = nil
            // Brief yield so the loading view renders before disk IO.
            await Task.yield()
            let p = loadPreview()
            preview = p
            loadState = (p == nil) ? .failed : .loaded
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading preview…")
                .foregroundStyle(.secondaryText)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    /// Synchronously load the theme preview. Tries every candidate URL
    /// (user dir overrides bundled).
    private func loadPreview() -> ThemePreview? {
        guard !themeName.isEmpty else { return nil }
        for url in ThemeFileResolver.candidateURLs(for: themeName) {
            if let p = ThemePicker.parsePreview(at: url) {
                return p
            }
        }
        NSLog("[Settings] preview load failed for theme '\(themeName)'")
        return nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(.secondaryText)
            Text("Theme preview")
                .font(.callout.weight(.semibold))
            Text("·")
                .foregroundStyle(.tertiaryText)
            Text(themeName.isEmpty ? "Default" : themeName)
                .font(.callout)
                .foregroundStyle(.secondaryText)
            Spacer()
            Button("Close") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var noPreviewView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Preview unavailable")
                .font(.headline)
            Text("Couldn't parse this theme's colors. The theme file may use a non-hex color format we don't yet support.")
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                // Re-trigger the .task by toggling loadState — cheap retry.
                loadState = .loading
                Task {
                    await Task.yield()
                    let p = loadPreview()
                    preview = p
                    loadState = (p == nil) ? .failed : .loaded
                }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .controlSize(.regular)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mock terminal

    @ViewBuilder
    private func mockTerminal(_ p: ThemePreview) -> some View {
        let bg     = p.background ?? Color.black
        let fg     = p.foreground ?? Color.white
        // Timestamps are dimmed by fading the foreground, NOT by a palette slot
        // (no ANSI slot is reliably "dim" — some themes repurpose slot 8 as a
        // bright accent). The terminal colorizer dims via the `faint` flag,
        // which multiplies fg alpha by `faint-opacity` (default 0.5); match it.
        let dim    = fg.opacity(0.5)
        // ANSI palette (0=black, 1=red, 2=green, 3=yellow, 4=blue,
        // 5=magenta, 6=cyan, 7=white; 8-15 = bright variants).
        // The semantic mapping used below (log level / boolean → color) MUST match
        // the terminal colorizer's canonical `Slot` map in src/termio/colorize.zig
        // so this preview shows exactly what the terminal renders.
        let red    = p.palette[1] ?? p.palette[9]  ?? Color.red
        let green  = p.palette[2] ?? p.palette[10] ?? Color.green
        let yellow = p.palette[3] ?? p.palette[11] ?? Color.yellow
        let blue   = p.palette[4] ?? p.palette[12] ?? Color.blue
        let magent = p.palette[5] ?? p.palette[13] ?? Color.pink
        let cyan   = p.palette[6] ?? p.palette[14] ?? Color.cyan

        VStack(alignment: .leading, spacing: 2) {
            // Prompt + git status
            prompt(fg: fg, user: green, path: blue, cmd: "git status")

            (Text("On branch ").foregroundColor(fg)
             + Text("main").foregroundColor(green)).fixedSize(horizontal: false, vertical: true)
            (Text("Your branch is up to date with '").foregroundColor(fg)
             + Text("origin/main").foregroundColor(green)
             + Text("'.").foregroundColor(fg))

            spacer

            Text("Changes not staged for commit:").foregroundColor(fg)
            (Text("  ").foregroundColor(fg)
             + Text("modified:").foregroundColor(yellow)
             + Text("   src/main.zig").foregroundColor(yellow))
            (Text("  ").foregroundColor(fg)
             + Text("modified:").foregroundColor(yellow)
             + Text("   README.md").foregroundColor(yellow))

            spacer

            Text("Untracked files:").foregroundColor(fg)
            (Text("  ").foregroundColor(fg)
             + Text("new.txt").foregroundColor(red))

            spacer

            // Logs section
            prompt(fg: fg, user: green, path: blue, cmd: "tail -n 6 app.log")

            log(time: "2026-06-13 14:00:01", level: "DEBUG", levelColor: cyan,
                message: "Connecting to db at localhost:5432", fg: fg, dim: dim)
            log(time: "2026-06-13 14:00:02", level: "INFO ", levelColor: blue,
                message: "Server started on port 3000", fg: fg, dim: dim)
            log(time: "2026-06-13 14:00:05", level: "INFO ", levelColor: blue,
                message: "Loaded 42 routes (114 ms)", fg: fg, dim: dim)
            log(time: "2026-06-13 14:00:18", level: "WARN ", levelColor: yellow,
                message: "Deprecated call: /api/v1/users (use v2)", fg: fg, dim: dim)
            log(time: "2026-06-13 14:00:22", level: "ERROR", levelColor: red,
                message: "Connection refused to db:5432", fg: fg, dim: dim)
            log(time: "2026-06-13 14:00:23", level: "FATAL", levelColor: magent,
                message: "Recovery failed after 3 attempts", fg: fg, dim: dim)
            // Booleans are colored wherever they appear (true/yes/enabled = green,
            // false/no/disabled = red) — mirrors boolColor in src/termio/colorize.zig.
            (log(time: "2026-06-13 14:00:24", level: "INFO ", levelColor: blue,
                 message: "Flags: cache=", fg: fg, dim: dim)
             + Text("true").foregroundColor(green)
             + Text(" retries=").foregroundColor(fg)
             + Text("false").foregroundColor(red)
             + Text(" verbose=").foregroundColor(fg)
             + Text("no").foregroundColor(red))

            spacer

            // Status markers
            prompt(fg: fg, user: green, path: blue, cmd: "make test")
            testResultsLine(green: green, red: red, yellow: yellow, fg: fg, dim: dim)
            buildResultLine(green: green, magent: magent, fg: fg)

            spacer

            // Final prompt with cursor
            finalPromptLine(green: green, blue: blue, fg: fg, cursor: p.palette[7] ?? fg)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }

    // MARK: - Helpers

    private var spacer: some View {
        Text(" ").font(.system(size: 12, design: .monospaced)).fixedSize()
    }

    /// `user@host:path $ cmd` prompt line.
    private func prompt(fg: Color, user: Color, path: Color, cmd: String) -> Text {
        Text("sarv@SarvTerminal").foregroundColor(user)
        + Text(":").foregroundColor(fg)
        + Text("~/projects/ghostty").foregroundColor(path)
        + Text(" $ ").foregroundColor(fg)
        + Text(cmd).foregroundColor(fg)
    }

    /// `[time] [LEVEL] message` with the level colored.
    private func log(
        time: String,
        level: String,
        levelColor: Color,
        message: String,
        fg: Color,
        dim: Color
    ) -> Text {
        Text("[\(time)] ").foregroundColor(dim)
        + Text("[\(level)] ").foregroundColor(levelColor)
        + Text(message).foregroundColor(fg)
    }

    private func testResultsLine(green: Color, red: Color, yellow: Color, fg: Color, dim: Color) -> Text {
        let pass = Text("✓").foregroundColor(green) + Text(" 142 passed").foregroundColor(fg)
        let fail = Text("✗").foregroundColor(red) + Text(" 3 failed").foregroundColor(fg)
        let skip = Text("•").foregroundColor(yellow) + Text(" 12 skipped").foregroundColor(dim)
        let gap = Text("    ").foregroundColor(fg)
        return pass + gap + fail + gap + skip
    }

    private func buildResultLine(green: Color, magent: Color, fg: Color) -> Text {
        let prefix = Text("Build ").foregroundColor(fg) + Text("succeeded").foregroundColor(green)
        let suffix = Text(" in ").foregroundColor(fg) + Text("2.34s").foregroundColor(magent)
        return prefix + suffix
    }

    private func finalPromptLine(green: Color, blue: Color, fg: Color, cursor: Color) -> Text {
        let userHost = Text("sarv@SarvTerminal").foregroundColor(green) + Text(":").foregroundColor(fg)
        let pathAndShell = Text("~/projects/ghostty").foregroundColor(blue) + Text(" $ ").foregroundColor(fg)
        return userHost + pathAndShell + Text("█").foregroundColor(cursor)
    }
}
