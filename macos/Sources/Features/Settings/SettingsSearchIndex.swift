import Foundation

/// A single searchable setting. Searching the Settings window matches against
/// these so typing "opacity", "ligature", "master password", etc. surfaces the
/// actual control and the section it lives in — not just section names.
///
/// This catalog is hand-maintained alongside the section views (the same way
/// `SettingsSection.keywords` already is). Keep an entry per user-facing control.
struct SettingsSearchEntry: Identifiable {
    let title: String
    let section: SettingsSection
    let keywords: [String]

    var id: String { "\(section.rawValue).\(title)" }

    func matches(_ query: String) -> Bool {
        if title.lowercased().contains(query) { return true }
        if section.title.lowercased().contains(query) { return true }
        return keywords.contains { $0.contains(query) }
    }

    static func e(_ title: String, _ section: SettingsSection, _ keywords: String...) -> SettingsSearchEntry {
        SettingsSearchEntry(title: title, section: section, keywords: keywords)
    }

    /// Every searchable setting across the visible sections.
    static let all: [SettingsSearchEntry] = [
        // General
        e("Default command", .general, "command", "shell", "program", "executable"),
        e("Working directory", .general, "cwd", "directory", "folder", "path", "home"),
        e("Confirm close", .general, "quit", "close", "confirm", "surface"),
        e("Quit after last window", .general, "quit", "exit", "last window"),
        e("Hide mouse while typing", .general, "mouse", "pointer", "cursor", "hide"),
        e("Focus follows mouse", .general, "focus", "mouse", "hover"),
        e("Scroll speed", .general, "scroll", "speed", "multiplier", "wheel"),
        e("Detect URLs", .general, "link", "url", "hyperlink", "open"),
        e("Copy on select", .general, "copy", "selection", "clipboard"),
        e("Clipboard read", .general, "clipboard", "paste", "read", "access"),
        e("Clipboard write", .general, "clipboard", "copy", "write", "access"),
        e("Paste protection", .general, "paste", "protection", "safe", "warn"),
        e("Scrollback limit", .general, "scrollback", "buffer", "history", "memory", "lines"),

        // Appearance
        e("Background color", .appearance, "background", "color", "bg"),
        e("Background opacity", .appearance, "opacity", "transparency", "alpha", "translucent"),
        e("Background blur", .appearance, "blur", "vibrancy", "glass", "frosted"),
        e("Foreground color", .appearance, "foreground", "text", "color"),
        e("Cursor color", .appearance, "cursor", "caret", "color"),
        e("Selection foreground", .appearance, "selection", "highlight", "foreground", "color"),
        e("Selection background", .appearance, "selection", "highlight", "background", "color"),
        e("Bold color", .appearance, "bold", "bright", "color"),
        e("Background image", .appearance, "image", "wallpaper", "picture", "photo", "background"),
        e("Background image opacity", .appearance, "image", "opacity", "wallpaper"),
        e("Background image fit", .appearance, "image", "fit", "cover", "contain", "stretch", "scale"),
        e("Background image position", .appearance, "image", "position", "align", "center"),
        e("Theme", .appearance, "theme", "scheme", "palette", "colors", "preset"),
        e("Window theme", .appearance, "window", "theme", "light", "dark", "appearance", "mode"),

        // Font
        e("Font family", .font, "font", "family", "typeface", "monospace"),
        e("Font size", .font, "font", "size", "points", "scale", "bigger", "smaller"),
        e("Font features / ligatures", .font, "ligature", "feature", "opentype", "calt"),
        e("Bold text thickening", .font, "thicken", "bold", "weight", "heavy"),
        e("Cell width", .font, "cell", "width", "spacing", "horizontal"),
        e("Cell height", .font, "cell", "height", "line", "spacing", "vertical"),

        // Cursor
        e("Cursor style", .cursor, "cursor", "caret", "block", "bar", "underline", "beam"),
        e("Cursor blink", .cursor, "cursor", "blink", "flash"),
        e("Cursor text color", .cursor, "cursor", "text", "color"),
        e("Cursor opacity", .cursor, "cursor", "opacity", "transparency"),
        e("Click to move cursor", .cursor, "cursor", "click", "move", "prompt"),

        // Window
        e("Window decoration", .window, "decoration", "titlebar", "border", "chrome"),
        e("Window save state", .window, "save", "restore", "state", "session"),
        e("Step resize", .window, "resize", "step", "cell", "snap"),
        e("Window padding", .window, "padding", "margin", "inset", "spacing"),

        // Keybinds
        e("Keyboard shortcuts", .keybinds, "keybind", "shortcut", "hotkey", "binding", "key", "chord"),

        // Shell Integration
        e("Shell integration", .shellIntegration, "shell", "integration", "bash", "zsh", "fish", "detect"),
        e("Shell integration features", .shellIntegration, "cursor", "sudo", "title", "ssh", "terminfo", "path", "prompt"),

        // SFTP
        e("Auto-save edits", .sftp, "sftp", "autosave", "auto-save", "save", "editor"),
        e("Confirm before deleting", .sftp, "sftp", "delete", "confirm", "trash"),
        e("Show hidden files", .sftp, "sftp", "hidden", "dotfiles", "show"),

        // Sync
        e("Enable sync", .sync, "sync", "backup", "enable", "cloud"),
        e("Sync provider", .sync, "sync", "github", "folder", "provider", "icloud", "dropbox"),
        e("Repository URL", .sync, "sync", "github", "repo", "url", "repository"),
        e("Access token", .sync, "sync", "github", "token", "pat", "credential"),
        e("Master password", .sync, "sync", "master", "password", "encrypt", "key"),
        e("Pull / Sync now", .sync, "sync", "pull", "push", "upload", "download"),

        // Advanced
        e("Edit config file", .advanced, "config", "edit", "file", "raw", "editor"),
        e("Open config externally", .advanced, "config", "external", "editor", "open"),
    ]
}
