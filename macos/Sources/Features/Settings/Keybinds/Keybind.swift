import Foundation

/// One parsed `keybind = …` line from the config file.
///
/// Config syntax (simplified — full grammar in Binding.zig:30-70):
///
/// ```
/// keybind = [flags:]<mod1>+<mod2>+...+<key>[>chord]=action[:param]
/// ```
///
/// Examples:
/// - `ctrl+c=copy_to_clipboard`
/// - `cmd+t=new_tab`
/// - `global:cmd+grave=toggle_quick_terminal`
/// - `ctrl+a>n=new_window` (chord: ctrl+a then n)
/// - `unconsumed:ctrl+r=reload_config`
struct KeybindEntry: Identifiable, Hashable {
    let id: UUID
    /// Original source line — used for round-tripping. Edit operations
    /// preserve this when finding the matching line to replace.
    var rawLine: String
    var trigger: KeybindTrigger
    var action: String          // includes any `:param` suffix
}

/// The key + modifier + flags side of a keybind.
struct KeybindTrigger: Hashable {
    var modifiers: KeybindModifiers
    /// Key name (e.g. "c", "tab", "f1", "arrow_left", "grave"). Single
    /// character or a special-key identifier.
    var key: String
    /// Optional follow-up press in a chord sequence (e.g. ctrl+a > n).
    /// nil when not a chord.
    var chord: ChordContinuation?
    /// Binding-level flags (global / all / unconsumed / performable).
    var flags: KeybindFlags

    /// Render as a config-file string (without the leading "keybind =").
    var configString: String {
        var s = ""
        if flags.global { s += "global:" }
        if flags.all { s += "all:" }
        if flags.unconsumed { s += "unconsumed:" }
        if flags.performable { s += "performable:" }
        s += modifiers.configString
        s += key
        if let chord {
            s += ">"
            s += chord.modifiers.configString
            s += chord.key
        }
        return s
    }
}

struct ChordContinuation: Hashable {
    var modifiers: KeybindModifiers
    var key: String
}

struct KeybindModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let ctrl    = KeybindModifiers(rawValue: 1 << 0)
    static let cmd     = KeybindModifiers(rawValue: 1 << 1)
    static let shift   = KeybindModifiers(rawValue: 1 << 2)
    static let opt     = KeybindModifiers(rawValue: 1 << 3)
    static let `super` = KeybindModifiers(rawValue: 1 << 4)

    /// Render as `ctrl+cmd+shift+` (with trailing `+`).
    /// Empty modifier set returns "".
    var configString: String {
        var parts: [String] = []
        if contains(.ctrl) { parts.append("ctrl") }
        if contains(.cmd) { parts.append("cmd") }
        if contains(.shift) { parts.append("shift") }
        if contains(.opt) { parts.append("alt") }   // Ghostty uses "alt" / "opt" interchangeably; "alt" is canonical
        if contains(.super) { parts.append("super") }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "+") + "+"
    }

    /// Compact symbolic rendering for the UI (⌃⌘⇧⌥).
    var symbolicLabel: String {
        var s = ""
        if contains(.ctrl) { s += "⌃" }
        if contains(.opt) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.cmd) { s += "⌘" }
        if contains(.super) { s += "❖" }
        return s
    }
}

struct KeybindFlags: Hashable {
    var global: Bool = false
    var all: Bool = false
    var unconsumed: Bool = false
    var performable: Bool = false

    var any: Bool { global || all || unconsumed || performable }

    /// Short human label (e.g. "global, unconsumed") or empty string.
    var label: String {
        var parts: [String] = []
        if global { parts.append("global") }
        if all { parts.append("all") }
        if unconsumed { parts.append("unconsumed") }
        if performable { parts.append("performable") }
        return parts.joined(separator: ", ")
    }
}

/// Map a Ghostty config-format key name (e.g. "arrow_up", "tab", "f1", "a")
/// to a compact display string suitable for keycap chips. Used everywhere
/// shortcuts are rendered.
enum KeybindKeyGlyph {
    static func display(_ rawKey: String) -> String {
        let k = rawKey.lowercased()
        switch k {
        // Arrows
        case "arrow_up":    return "↑"
        case "arrow_down":  return "↓"
        case "arrow_left":  return "←"
        case "arrow_right": return "→"
        // Editing / whitespace
        case "enter", "return":    return "⏎"
        case "tab":         return "⇥"
        case "space":       return "␣"
        case "backspace":   return "⌫"
        case "delete":      return "⌦"
        case "escape":      return "⎋"
        // Navigation
        case "home":        return "↖︎"
        case "end":         return "↘︎"
        case "page_up":     return "⇞"
        case "page_down":   return "⇟"
        // Function keys: F1..F12 as-is
        case "f1", "f2", "f3", "f4", "f5", "f6",
             "f7", "f8", "f9", "f10", "f11", "f12":
            return k.uppercased()
        // Generic: single character / punctuation — uppercase it for chip look.
        default:
            return rawKey.uppercased()
        }
    }
}

/// Curated list of the most-used Ghostty keybind actions. Full list at
/// ~75 entries lives in `src/input/Binding.zig` and can be enumerated via
/// `ghostty +list-actions`. We expose this subset in the picker; users
/// can still type any other action as free text.
struct KeybindAction {
    let name: String
    let label: String
    let category: String

    /// SarvTerminal app-level actions (command palette, local terminal) are
    /// handled by the app, not the Ghostty config. Their bindings live in
    /// `AppKeybindStore` and are edited separately from Ghostty keybinds, but
    /// they're still rebindable.
    var isAppAction: Bool { name.hasPrefix("app:") }
}

let kKeybindActions: [KeybindAction] = [
    // Clipboard
    .init(name: "copy_to_clipboard:mixed", label: "Copy", category: "Clipboard"),
    .init(name: "paste_from_clipboard", label: "Paste", category: "Clipboard"),
    .init(name: "paste_from_selection", label: "Paste selection", category: "Clipboard"),
    .init(name: "copy_url_to_clipboard", label: "Copy hovered URL", category: "Clipboard"),
    .init(name: "copy_title_to_clipboard", label: "Copy window title", category: "Clipboard"),

    // Selection
    .init(name: "select_all", label: "Select all", category: "Selection"),

    // Font
    .init(name: "increase_font_size:1", label: "Increase font size", category: "Font"),
    .init(name: "decrease_font_size:1", label: "Decrease font size", category: "Font"),
    .init(name: "reset_font_size", label: "Reset font size", category: "Font"),

    // Scroll
    .init(name: "scroll_page_up", label: "Scroll page up", category: "Scroll"),
    .init(name: "scroll_page_down", label: "Scroll page down", category: "Scroll"),
    .init(name: "scroll_to_top", label: "Scroll to top", category: "Scroll"),
    .init(name: "scroll_to_bottom", label: "Scroll to bottom", category: "Scroll"),

    // Tabs — SarvTerminal app-level, rebindable (see AppKeybindStore). These
    // replace Ghostty's native `new_tab` (unused in the single-window model).
    .init(name: "app:command_palette", label: "New tab / command palette", category: "Tabs"),
    .init(name: "app:new_local_terminal", label: "New Local Terminal Tab", category: "Tabs"),
    .init(name: "app:reopen_closed_tab", label: "Reopen Closed Tab", category: "Tabs"),
    .init(name: "previous_tab", label: "Previous tab", category: "Tabs"),
    .init(name: "next_tab", label: "Next tab", category: "Tabs"),
    .init(name: "last_tab", label: "Last tab", category: "Tabs"),

    // Windows
    .init(name: "new_window", label: "New window", category: "Windows"),
    .init(name: "close_window", label: "Close window", category: "Windows"),
    .init(name: "toggle_maximize", label: "Toggle maximize", category: "Windows"),
    .init(name: "toggle_fullscreen", label: "Toggle fullscreen", category: "Windows"),

    // Splits — right/down open the palette to choose the new pane's target
    // (app-level, rebindable). Other split ops stay native Ghostty actions.
    .init(name: "app:split_right", label: "Split right (choose target)", category: "Splits"),
    .init(name: "app:split_down", label: "Split down (choose target)", category: "Splits"),
    .init(name: "goto_split:next", label: "Next split", category: "Splits"),
    .init(name: "goto_split:previous", label: "Previous split", category: "Splits"),
    .init(name: "toggle_split_zoom", label: "Toggle split zoom", category: "Splits"),
    .init(name: "equalize_splits", label: "Equalize splits", category: "Splits"),

    // Search
    .init(name: "start_search", label: "Find", category: "Search"),

    // Config
    .init(name: "open_config", label: "Open config file", category: "Config"),
    .init(name: "reload_config", label: "Reload config", category: "Config"),

    // UI
    .init(name: "inspector:toggle", label: "Toggle inspector", category: "UI"),
    .init(name: "toggle_command_palette", label: "Toggle command palette", category: "UI"),
    .init(name: "toggle_quick_terminal", label: "Toggle Quick Terminal", category: "UI"),

    // System
    .init(name: "quit", label: "Quit", category: "System"),
    .init(name: "clear_screen", label: "Clear screen", category: "System"),
]
