import Foundation
import SwiftUI
import GhosttyKit

/// Read-only helpers on `Ghostty.Config` for settings the upstream Swift
/// wrapper hasn't typed yet. Kept in our fork so we don't need to touch
/// `Ghostty.Config.swift` for every additional config key.
///
/// **Important — match the C type exactly.** `ghostty_config_get(cfg, void*, key, len)`
/// writes the value as the concrete C type of the field. Mismatching the
/// receiver's size = stack corruption. Reference:
///
/// - `?Path`         →  `ghostty_config_path_s` (16 bytes: `const char* + bool`)
/// - `Color`         →  `ghostty_config_color_s` (3 bytes packed)
/// - `?TerminalColor` →  `ghostty_config_color_s`, get returns `false` if unset
/// - `f32`           →  `float` (4 bytes)
/// - `f64`           →  `double` (8 bytes)
/// - String enums    →  `const char*` (8-byte pointer)
/// - `bool`          →  `bool` (1 byte)
/// - `RepeatableString` → `const char*` (only the first entry is read here)
extension Ghostty.Config {

    // MARK: - Foreground / cursor / selection colors

    /// `foreground` — non-optional Color, defaults to white.
    var foregroundColor: Color {
        guard let config = self.config else { return .white }
        var color = ghostty_config_color_s()
        let key = "foreground"
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .white
        }
        return colorFrom(color)
    }

    /// `cursor-color` — `?TerminalColor`. nil when unset (use Ghostty's default).
    var cursorColor: Color? { readOptionalColor(key: "cursor-color") }

    /// `selection-foreground` — `?TerminalColor`. nil = unset.
    var selectionForeground: Color? { readOptionalColor(key: "selection-foreground") }

    /// `selection-background` — `?TerminalColor`. nil = unset.
    var selectionBackground: Color? { readOptionalColor(key: "selection-background") }

    // MARK: - Theme

    /// `theme` — single name (light/dark pair encoded as `light,dark` is rare;
    /// we expose the raw string and let advanced users edit it directly).
    ///
    /// IMPORTANT: `theme` is NOT a plain `const char*` in libghostty's config API
    /// (it's a light/dark Theme value), so reading it via `ghostty_config_get`
    /// into a `char*` returns a garbage pointer (e.g. "0x96f") — which then gets
    /// written back, corrupting the config. We control the config file writes, so
    /// read the value straight from the file instead.
    var themeName: String? {
        Ghostty.Config.rawConfigFileValue("theme")
    }

    /// Read a raw `key = value` line directly from the on-disk config file.
    /// Used for keys whose libghostty C type isn't a plain string.
    static func rawConfigFileValue(_ key: String) -> String? {
        let path = AppPaths.ghosttyConfigFile
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: - Font

    /// `font-family` — `RepeatableString`. We read the first entry (most users
    /// only set one). Multi-family editing belongs in a dedicated UI.
    var fontFamily: String {
        readString(key: "font-family") ?? ""
    }

    /// `font-size` — `f32`. Returned as Double for UI convenience.
    var fontSize: Double {
        guard let config = self.config else { return 13.0 }
        var v: Float = 13.0
        let key = "font-size"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Double(v)
    }

    /// `font-feature` — `RepeatableString`. First entry only for now.
    var fontFeature: String {
        readString(key: "font-feature") ?? ""
    }

    // MARK: - Cursor

    /// `cursor-style` — enum exposed as string (block / bar / underline / block_hollow).
    var cursorStyle: String { readString(key: "cursor-style") ?? "block" }

    /// `cursor-style-blink` — `?bool`. `nil` = unset (Ghostty default).
    var cursorStyleBlink: Bool? {
        guard let config = self.config else { return nil }
        var v: Bool = false
        let key = "cursor-style-blink"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }
        return v
    }

    /// `cursor-text` — `?TerminalColor`. Color of text *under* the cursor.
    var cursorText: Color? { readOptionalColor(key: "cursor-text") }

    /// `cursor-opacity` — `f64`, 0.0–1.0.
    var cursorOpacity: Double {
        guard let config = self.config else { return 1.0 }
        var v: Double = 1.0
        let key = "cursor-opacity"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// `cursor-click-to-move` — bool.
    var cursorClickToMove: Bool {
        guard let config = self.config else { return true }
        var v: Bool = true
        let key = "cursor-click-to-move"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    // MARK: - General

    /// `command` — a Zig union we can't read via the C API, so read the raw
    /// value from the config file (preserves round-trip for the common
    /// single-command case).
    var command: String { readString(key: "command") ?? "" }

    /// `working-directory` — path / "home" / "inherit". Read raw from file.
    var workingDirectory: String { readString(key: "working-directory") ?? "" }

    /// `mouse-scroll-multiplier` — f64 (default 1.0).
    var mouseScrollMultiplier: Double {
        guard let config = self.config else { return 1.0 }
        var v: Double = 1.0
        let key = "mouse-scroll-multiplier"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// `clipboard-paste-protection` — bool (default true; warns only on
    /// multi-line non-bracketed pastes, see Config.zig).
    var clipboardPasteProtection: Bool { readBool(key: "clipboard-paste-protection", default: true) }

    /// `link-url` — bool, auto-detect URLs (default true).
    var linkURL: Bool { readBool(key: "link-url", default: true) }

    // MARK: - Font (advanced)

    /// `font-thicken` — bool, synthetic boldening.
    var fontThicken: Bool { readBool(key: "font-thicken", default: false) }

    /// `adjust-cell-width` / `adjust-cell-height` — metric modifiers (e.g.
    /// "10%" or "-1"). Special types; read raw from file.
    var adjustCellWidth: String { readString(key: "adjust-cell-width") ?? "" }
    var adjustCellHeight: String { readString(key: "adjust-cell-height") ?? "" }

    // MARK: - Window (advanced)

    /// `window-padding-x` / `window-padding-y` — point values (or "x,y" range).
    /// Read raw from file.
    var windowPaddingX: String { readString(key: "window-padding-x") ?? "" }
    var windowPaddingY: String { readString(key: "window-padding-y") ?? "" }

    /// `bold-color` — `?BoldColor` (a color or "bright"). Read raw from file.
    var boldColor: String { readString(key: "bold-color") ?? "" }

    /// `shell-integration` — enum: detect / none / bash / zsh / fish / elvish / nushell.
    var shellIntegration: String { readString(key: "shell-integration") ?? "detect" }

    /// `shell-integration-features` — the raw override list (e.g. "no-cursor,
    /// sudo"). Read from the config file; unlisted features keep their defaults.
    var shellIntegrationFeatures: String? { readString(key: "shell-integration-features") }

    /// `confirm-close-surface` — enum: true / false / always.
    var confirmCloseSurface: String { readString(key: "confirm-close-surface") ?? "true" }

    /// `quit-after-last-window-closed` — bool (default depends on OS).
    var quitAfterLastWindowClosed: Bool {
        guard let config = self.config else { return false }
        var v: Bool = false
        let key = "quit-after-last-window-closed"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// `scrollback-limit` — usize. Returned as Int (likely won't exceed 2^63).
    var scrollbackLimit: Int {
        guard let config = self.config else { return 10_000_000 }
        var v: UInt = 10_000_000
        let key = "scrollback-limit"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Int(v)
    }

    // MARK: - Window

    /// `window-decoration` — enum: auto / none / server / client.
    var windowDecoration: String { readString(key: "window-decoration") ?? "auto" }

    /// `window-padding-balance` — enum (.false/.true/.equal). Read via string
    /// to avoid any int/bool size mismatch with the Zig enum's backing type.
    /// Maps to bool for the form (true if anything other than ".false").
    var windowPaddingBalance: Bool {
        let s = readString(key: "window-padding-balance") ?? "false"
        return s != "false"
    }

    // MARK: - Tabs

    /// `macos-titlebar-style` — enum: native / transparent / tabs / hidden.
    var macosTitlebarStyleString: String { readString(key: "macos-titlebar-style") ?? "transparent" }

    /// `window-new-tab-position` — enum: current / end.
    var windowNewTabPositionString: String { readString(key: "window-new-tab-position") ?? "current" }

    // MARK: - Shell Integration features
    // NOTE: `shell-integration-features` is a packed struct in Ghostty and
    // can't be read via the simple string pattern. We don't read it for
    // now — the form initializes with an empty string and writing to the
    // config file (via Save) still works because Ghostty's parser accepts
    // the same "cursor, no-sudo, title" comma form on write.

    // MARK: - Behavior

    var mouseHideWhileTyping: Bool {
        guard let config = self.config else { return false }
        var v: Bool = false
        let key = "mouse-hide-while-typing"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// `copy-on-select` — enum: true / false / clipboard.
    var copyOnSelect: String { readString(key: "copy-on-select") ?? "false" }

    /// `clipboard-read` — enum: ask / allow / deny.
    var clipboardRead: String { readString(key: "clipboard-read") ?? "ask" }

    /// `clipboard-write` — enum: ask / allow / deny.
    var clipboardWrite: String { readString(key: "clipboard-write") ?? "allow" }

    // MARK: - Background image (kept here for completeness)

    /// `background-image` — `?Path`, exposed as the absolute path or nil.
    var backgroundImage: String? {
        guard let config = self.config else { return nil }
        var v = ghostty_config_path_s()
        let key = "background-image"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))),
              let cstr = v.path else { return nil }
        let str = String(cString: cstr)
        return str.isEmpty ? nil : str
    }

    /// `background-image-opacity` — `f32`.
    var backgroundImageOpacity: Double {
        guard let config = self.config else { return 1.0 }
        var v: Float = 1.0
        let key = "background-image-opacity"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Double(v)
    }

    /// `background-image-position` — enum → string.
    var backgroundImagePosition: String { readString(key: "background-image-position") ?? "center" }

    /// `background-image-fit` — enum → string.
    var backgroundImageFit: String { readString(key: "background-image-fit") ?? "contain" }

    /// `background-image-repeat` — bool.
    var backgroundImageRepeat: Bool {
        guard let config = self.config else { return false }
        var v: Bool = false
        let key = "background-image-repeat"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    // MARK: - Private helpers

    /// Read a `?TerminalColor` or `?Color`. Returns nil when unset.
    private func readOptionalColor(key: String) -> Color? {
        guard let config = self.config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }
        return colorFrom(color)
    }

    /// Read a string-valued config key — from the config FILE, not
    /// `ghostty_config_get`.
    ///
    /// Several config fields are NOT plain `const char*` in libghostty's C API:
    /// `theme` is a light/dark value, `font-family`/`font-feature` are
    /// `RepeatableString`s, etc. Reading those into a `char*` fails (nil) or
    /// returns a garbage pointer, which is why the Settings pickers showed
    /// "Default"/"System default" even when the value was set. The config file
    /// is the source of truth for everything the Settings UI writes, so we parse
    /// it directly — reliable for every string key, no per-key C-type matching.
    private func readString(key: String) -> String? {
        Ghostty.Config.rawConfigFileValue(key)
    }

    /// Read a bool config key via the typed getter (resolves Ghostty's own
    /// default when the key is unset). `defaultValue` covers the get-failure case.
    private func readBool(key: String, default defaultValue: Bool) -> Bool {
        guard let config = self.config else { return defaultValue }
        var v: Bool = defaultValue
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    private func colorFrom(_ c: ghostty_config_color_s) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
