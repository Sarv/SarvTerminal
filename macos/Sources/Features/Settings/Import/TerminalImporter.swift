import Foundation

/// Import settings from another terminal emulator.
///
/// Two-tier design (see the product discussion): the **deterministic**
/// appearance layer (theme/colors, font, size, opacity, padding, cursor) is
/// parsed and auto-mapped silently; **keybindings** are ambiguous across
/// emulators (every one names actions differently), so we only *suggest* a
/// mapping here and let the user confirm/skip each one in the UI.
///
/// This file is the pure engine (Foundation only): parse a source config into a
/// normalized ``ImportedConfig``. Writing it to disk lives in
/// ``TerminalImportApplier``; the review UI is ``ImportSettingsSheet``.

// MARK: - Source

enum ImportSource: String, CaseIterable, Identifiable {
    case ghostty, alacritty, kitty, iterm2, wezterm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ghostty:   return "Ghostty"
        case .alacritty: return "Alacritty"
        case .kitty:     return "kitty"
        case .iterm2:    return "iTerm2"
        case .wezterm:   return "WezTerm"
        }
    }

    /// File extensions shown in the open panel. `""` matches extensionless
    /// files (e.g. Ghostty's `config`, kitty's `kitty.conf` is `.conf`).
    var allowedExtensions: [String] {
        switch self {
        case .ghostty:   return ["", "config", "conf", "txt"]
        case .alacritty: return ["toml"]
        case .kitty:     return ["conf"]
        case .iterm2:    return ["itermcolors", "plist", "xml"]
        case .wezterm:   return ["lua"]
        }
    }

    /// A short note about coverage, shown under the picker.
    var coverageNote: String {
        switch self {
        case .ghostty:   return "Same format — near 1:1 import."
        case .alacritty: return "Colors, font, padding, opacity, cursor, keybinds."
        case .kitty:     return "Colors, font, padding, opacity, cursor, keybinds."
        case .iterm2:    return "Colors only (.itermcolors has no font/keybinds)."
        case .wezterm:   return "Best-effort scrape of a Lua config (colors, font, keybinds)."
        }
    }
}

// MARK: - Normalized model

/// One imported keybinding awaiting the user's confirmation. `trigger` is
/// already in Ghostty syntax (e.g. `cmd+shift+t`); `sourceAction` is the raw
/// action from the source; `mappedAction` is our editable best-guess (nil = no
/// equivalent found, user must choose or skip).
struct ImportedKeybind: Identifiable {
    let id = UUID()
    var trigger: String
    var sourceAction: String
    var mappedAction: String?
    /// True when `trigger` already maps to a DIFFERENT action in SarvTerminal.
    var conflict: Bool = false
    /// Human explanation of the conflict (what the trigger is already bound to).
    var conflictDetail: String?
    /// User's choice in the review UI (defaults to importing when a mapping exists).
    var include: Bool = true
}

/// Everything we could extract from a foreign config, normalized to Ghostty
/// vocabulary. Colors are `#RRGGBB` strings; palette is index (0–15) → hex.
struct ImportedConfig {
    var source: ImportSource
    var fontFamily: String?
    var fontSize: Double?
    var backgroundOpacity: Double?
    var paddingX: Int?
    var paddingY: Int?
    var cursorStyle: String?      // block | bar | underline
    var themeName: String?        // a named theme reference (e.g. Ghostty's `theme =`)
    /// When true, apply reverts all color keys to SarvTerminal's default —
    /// used when the source named a theme we have no match for.
    var resetColorsToDefault: Bool = false
    var background: String?       // #RRGGBB
    var foreground: String?       // #RRGGBB
    var palette: [Int: String] = [:]
    var keybinds: [ImportedKeybind] = []
    var warnings: [String] = []

    var hasColors: Bool { background != nil || foreground != nil || !palette.isEmpty }

    /// Human-readable list of the appearance settings that were found — shown
    /// as the "auto-imported" summary in the review UI.
    var appearanceSummary: [String] {
        var out: [String] = []
        if hasColors {
            let n = palette.count + (background != nil ? 1 : 0) + (foreground != nil ? 1 : 0)
            out.append("Colors (\(n) values)")
        }
        if let f = fontFamily { out.append("Font: \(f)") }
        if let s = fontSize { out.append("Font size: \(clean(s))") }
        if let o = backgroundOpacity { out.append("Opacity: \(clean(o))") }
        if paddingX != nil || paddingY != nil {
            out.append("Padding: \(paddingX ?? 0)×\(paddingY ?? 0)")
        }
        if let c = cursorStyle { out.append("Cursor: \(c)") }
        return out
    }

    private func clean(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

// MARK: - Parser entry point

enum TerminalImporter {
    static func parse(source: ImportSource, fileURL: URL) throws -> ImportedConfig {
        let data = try Data(contentsOf: fileURL)
        if source == .iterm2 {
            return parseITerm2(data: data)
        }
        let text = String(decoding: data, as: UTF8.self)
        switch source {
        case .ghostty:   return parseGhostty(text)
        case .alacritty: return parseAlacritty(text)
        case .kitty:     return parseKitty(text)
        case .wezterm:   return parseWezTerm(text)
        case .iterm2:    return parseITerm2(data: data) // unreachable
        }
    }

    // MARK: Ghostty (key = value) — near 1:1

    private static func parseGhostty(_ text: String) -> ImportedConfig {
        var c = ImportedConfig(source: .ghostty)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "font-family":        c.fontFamily = unquote(val)
            case "font-size":          c.fontSize = Double(val)
            case "background-opacity":  c.backgroundOpacity = Double(val)
            case "window-padding-x":   c.paddingX = Int(val.split(separator: ",").first.map(String.init) ?? val)
            case "window-padding-y":   c.paddingY = Int(val.split(separator: ",").first.map(String.init) ?? val)
            case "cursor-style":       c.cursorStyle = normalizeCursor(val)
            case "theme":              c.themeName = unquote(val)
            case "background":         c.background = normalizeHex(val)
            case "foreground":         c.foreground = normalizeHex(val)
            case "palette":
                if let inner = val.firstIndex(of: "=") {
                    let idx = Int(val[..<inner].trimmingCharacters(in: .whitespaces))
                    let hex = normalizeHex(String(val[val.index(after: inner)...]))
                    if let idx, let hex { c.palette[idx] = hex }
                }
            case "keybind":
                // trigger=action
                if let sep = val.firstIndex(of: "=") {
                    let trig = String(val[..<sep])
                    let act = String(val[val.index(after: sep)...])
                    c.keybinds.append(ImportedKeybind(trigger: trig, sourceAction: act, mappedAction: act))
                }
            default: break
            }
        }
        return c
    }

    // MARK: Alacritty (TOML subset)

    private static func parseAlacritty(_ text: String) -> ImportedConfig {
        var c = ImportedConfig(source: .alacritty)
        var table = ""
        var binding: [String: String] = [:]

        func flushBinding() {
            if let key = binding["key"] {
                let trig = trigger(mods: binding["mods"], key: key, sep: "|")
                let act = binding["action"] ?? ""
                if !act.isEmpty {
                    c.keybinds.append(ImportedKeybind(
                        trigger: trig, sourceAction: act,
                        mappedAction: mapAlacrittyAction(act)))
                }
            }
            binding = [:]
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") {
                flushBinding()
                table = line.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                continue
            }
            if line.hasPrefix("[") {
                flushBinding()
                table = line.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if table.hasSuffix("keyboard.bindings") {
                binding[key] = unquote(val)
                continue
            }
            switch table {
            case "window":
                if key == "opacity" { c.backgroundOpacity = Double(val) }
                if key == "padding" {
                    let inner = inlineTable(val)
                    c.paddingX = Int(inner["x"] ?? "")
                    c.paddingY = Int(inner["y"] ?? "")
                }
            case "font":
                if key == "size" { c.fontSize = Double(val) }
            case "font.normal":
                if key == "family" { c.fontFamily = unquote(val) }
            case "cursor":
                if key == "style" {
                    let inner = inlineTable(val)
                    if let shape = inner["shape"] { c.cursorStyle = normalizeCursor(shape) }
                } else if key == "shape" {
                    c.cursorStyle = normalizeCursor(val)
                }
            case "colors.primary":
                if key == "background" { c.background = normalizeHex(val) }
                if key == "foreground" { c.foreground = normalizeHex(val) }
            case "colors.normal":
                if let i = ansiIndex(name: key, bright: false), let h = normalizeHex(val) { c.palette[i] = h }
            case "colors.bright":
                if let i = ansiIndex(name: key, bright: true), let h = normalizeHex(val) { c.palette[i] = h }
            default: break
            }
        }
        flushBinding()
        return c
    }

    // MARK: kitty (flat key value + map)

    private static func parseKitty(_ text: String) -> ImportedConfig {
        var c = ImportedConfig(source: .kitty)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first else { continue }
            let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "font_family":        c.fontFamily = val
            case "font_size":          c.fontSize = Double(val)
            case "background_opacity":  c.backgroundOpacity = Double(val)
            case "window_padding_width":
                c.paddingX = Int(Double(val) ?? 0); c.paddingY = c.paddingX
            case "cursor_shape":       c.cursorStyle = normalizeCursor(val)
            case "foreground":         c.foreground = normalizeHex(val)
            case "background":         c.background = normalizeHex(val)
            case "map":
                // map <trigger> <action...>
                let mp = val.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                if mp.count == 2 {
                    let trig = normalizeTriggerTokens(mp[0])
                    let act = mp[1]
                    c.keybinds.append(ImportedKeybind(
                        trigger: trig, sourceAction: act, mappedAction: mapKittyAction(act)))
                }
            default:
                if key.hasPrefix("color"), let i = Int(key.dropFirst("color".count)), let h = normalizeHex(val) {
                    c.palette[i] = h
                }
            }
        }
        return c
    }

    // MARK: iTerm2 (.itermcolors plist)

    private static func parseITerm2(data: Data) -> ImportedConfig {
        var c = ImportedConfig(source: .iterm2)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            c.warnings.append("Couldn't parse the .itermcolors file.")
            return c
        }
        func hex(_ any: Any?) -> String? {
            guard let d = any as? [String: Any] else { return nil }
            let r = (d["Red Component"] as? Double) ?? 0
            let g = (d["Green Component"] as? Double) ?? 0
            let b = (d["Blue Component"] as? Double) ?? 0
            return String(format: "#%02X%02X%02X",
                          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        for i in 0...15 { if let h = hex(dict["Ansi \(i) Color"]) { c.palette[i] = h } }
        c.background = hex(dict["Background Color"])
        c.foreground = hex(dict["Foreground Color"])
        return c
    }

    // MARK: WezTerm (Lua — best effort)

    private static func parseWezTerm(_ text: String) -> ImportedConfig {
        var c = ImportedConfig(source: .wezterm)
        c.warnings.append("WezTerm configs are Lua; only common keys are scraped, not evaluated.")

        c.fontFamily = firstMatch(#"wezterm\.font\s*[\('"]+([^'")]+)"#, text)
        if let s = firstMatch(#"font_size\s*=\s*([0-9.]+)"#, text) { c.fontSize = Double(s) }
        if let o = firstMatch(#"window_background_opacity\s*=\s*([0-9.]+)"#, text) { c.backgroundOpacity = Double(o) }
        if let l = firstMatch(#"window_padding\s*=\s*\{[^}]*left\s*=\s*([0-9]+)"#, text) { c.paddingX = Int(l) }
        if let t = firstMatch(#"window_padding\s*=\s*\{[^}]*top\s*=\s*([0-9]+)"#, text) { c.paddingY = Int(t) }
        if let cs = firstMatch(#"default_cursor_style\s*=\s*['"]([A-Za-z]+)['"]"#, text) { c.cursorStyle = normalizeCursor(cs) }
        c.foreground = normalizeHex(firstMatch(#"foreground\s*=\s*['"](#[0-9a-fA-F]{3,6})['"]"#, text) ?? "")
        c.background = normalizeHex(firstMatch(#"background\s*=\s*['"](#[0-9a-fA-F]{3,6})['"]"#, text) ?? "")
        if let ansi = firstMatch(#"ansi\s*=\s*\{([^}]*)\}"#, text) {
            for (i, h) in hexList(ansi).prefix(8).enumerated() { c.palette[i] = h }
        }
        if let brights = firstMatch(#"brights\s*=\s*\{([^}]*)\}"#, text) {
            for (i, h) in hexList(brights).prefix(8).enumerated() { c.palette[8 + i] = h }
        }
        // keys = { { key = 'x', mods = 'CMD', action = wezterm.action.Foo ... }, ... }
        for block in allMatches(#"\{[^{}]*key\s*=[^{}]*\}"#, text) {
            guard let key = firstMatch(#"key\s*=\s*['"]([^'"]+)['"]"#, block) else { continue }
            let mods = firstMatch(#"mods\s*=\s*['"]([^'"]+)['"]"#, block)
            let action = firstMatch(#"action\s*=\s*wezterm\.action\.([A-Za-z]+)"#, block) ?? "Unknown"
            let trig = trigger(mods: mods, key: key, sep: "|")
            c.keybinds.append(ImportedKeybind(
                trigger: trig, sourceAction: action, mappedAction: mapWezTermAction(action)))
        }
        return c
    }

    // MARK: - Normalization helpers

    private static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v.removeFirst(); v.removeLast()
        }
        return v
    }

    private static func normalizeHex(_ s: String) -> String? {
        let v = unquote(s)
        guard !v.isEmpty else { return nil }
        let hex = v.hasPrefix("#") ? String(v.dropFirst()) : v
        guard (hex.count == 6 || hex.count == 3), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex.uppercased()
    }

    /// block | bar | underline (Ghostty's `cursor-style` values).
    private static func normalizeCursor(_ s: String) -> String? {
        switch unquote(s).lowercased() {
        case let x where x.contains("beam") || x.contains("bar"): return "bar"
        case let x where x.contains("under"): return "underline"
        case let x where x.contains("block"): return "block"
        default: return nil
        }
    }

    /// Alacritty/WezTerm named ANSI color → palette index.
    private static func ansiIndex(name: String, bright: Bool) -> Int? {
        let base: Int
        switch name.lowercased() {
        case "black": base = 0
        case "red": base = 1
        case "green": base = 2
        case "yellow": base = 3
        case "blue": base = 4
        case "magenta": base = 5
        case "cyan": base = 6
        case "white": base = 7
        default: return nil
        }
        return bright ? base + 8 : base
    }

    /// Parse a TOML inline table `{ x = 10, y = 10 }` into a dictionary.
    private static func inlineTable(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let inner = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        for pair in inner.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = unquote(kv[1]) }
        }
        return out
    }

    /// Build a Ghostty trigger `cmd+shift+t` from source modifiers + key.
    /// `sep` is how the source joins modifiers ("|" for WezTerm/Alacritty).
    private static func trigger(mods: String?, key: String, sep: Character) -> String {
        var parts: [String] = []
        if let mods {
            for m in mods.split(whereSeparator: { $0 == sep || $0 == "+" }) {
                switch m.trimmingCharacters(in: .whitespaces).lowercased() {
                case "cmd", "command", "super": parts.append("cmd")
                case "ctrl", "control": parts.append("ctrl")
                case "shift": parts.append("shift")
                case "alt", "opt", "option": parts.append("alt")
                default: break
                }
            }
        }
        parts.append(normalizeKey(key))
        return parts.joined(separator: "+")
    }

    /// Normalize an already-joined trigger string (kitty's `cmd+t`).
    private static func normalizeTriggerTokens(_ s: String) -> String {
        let toks = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = toks.last else { return s }
        let mods = toks.dropLast().joined(separator: "+")
        return trigger(mods: mods.isEmpty ? nil : mods, key: key, sep: "+")
    }

    private static func normalizeKey(_ raw: String) -> String {
        let k = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")).lowercased()
        switch k {
        case "enter", "return": return "enter"
        case "space": return "space"
        case "tab": return "tab"
        case "escape", "esc": return "escape"
        case "backspace": return "backspace"
        case "leftarrow", "left": return "arrow_left"
        case "rightarrow", "right": return "arrow_right"
        case "uparrow", "up": return "arrow_up"
        case "downarrow", "down": return "arrow_down"
        case "equal", "plus": return "equal"
        case "minus": return "minus"
        default: return k
        }
    }

    // MARK: - Keybind action mapping (best effort → nil when no equivalent)

    private static func mapAlacrittyAction(_ a: String) -> String? {
        switch a {
        case "CreateNewTab": return "new_tab"
        case "CreateNewWindow", "SpawnNewInstance": return "new_window"
        case "Quit": return "quit"
        case "Copy": return "copy_to_clipboard"
        case "Paste": return "paste_from_clipboard"
        case "ToggleFullscreen": return "toggle_fullscreen"
        case "IncreaseFontSize": return "increase_font_size:1"
        case "DecreaseFontSize": return "decrease_font_size:1"
        case "ResetFontSize": return "reset_font_size"
        default: return nil
        }
    }

    private static func mapKittyAction(_ a: String) -> String? {
        let head = a.split(separator: " ").first.map(String.init) ?? a
        switch head {
        case "new_tab": return "new_tab"
        case "close_tab": return "close_surface"
        case "toggle_fullscreen": return "toggle_fullscreen"
        case "next_tab": return "next_tab"
        case "previous_tab": return "previous_tab"
        case "copy_to_clipboard": return "copy_to_clipboard"
        case "paste_from_clipboard": return "paste_from_clipboard"
        case "new_os_window": return "new_window"
        case "new_window": return "new_split:right"
        case "change_font_size":
            if a.contains("+") { return "increase_font_size:1" }
            if a.contains("-") { return "decrease_font_size:1" }
            return "reset_font_size"
        case "launch":
            if a.contains("vsplit") { return "new_split:right" }
            if a.contains("hsplit") { return "new_split:down" }
            return nil
        default: return nil
        }
    }

    private static func mapWezTermAction(_ a: String) -> String? {
        switch a {
        case "SpawnTab": return "new_tab"
        case "SpawnWindow": return "new_window"
        case "CloseCurrentPane", "CloseCurrentTab": return "close_surface"
        case "SplitHorizontal": return "new_split:right"
        case "SplitVertical": return "new_split:down"
        case "ClearScrollback": return "clear_screen"
        case "ToggleFullScreen": return "toggle_fullscreen"
        case "CopyTo": return "copy_to_clipboard"
        case "PasteFrom": return "paste_from_clipboard"
        case "IncreaseFontSize": return "increase_font_size:1"
        case "DecreaseFontSize": return "decrease_font_size:1"
        case "ResetFontSize": return "reset_font_size"
        default: return nil
        }
    }

    // MARK: - Regex helpers

    private static func firstMatch(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range),
              m.numberOfRanges > group, let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }

    private static func allMatches(_ pattern: String, _ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, options: [], range: range).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    private static func hexList(_ s: String) -> [String] {
        allMatches(#"#[0-9a-fA-F]{6}"#, s).compactMap { normalizeHex($0) }
    }
}
