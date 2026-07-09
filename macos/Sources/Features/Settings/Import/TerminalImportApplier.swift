import AppKit

/// Writes an ``ImportedConfig`` (plus the user's approved keybinds) into the
/// plaintext Ghostty config file and reloads. Appearance is written inline —
/// exactly how the Appearance settings section persists `background`/
/// `foreground` — so it lands in the same file Ghostty definitely loads.
enum TerminalImportApplier {

    struct Result {
        var appearanceCount: Int
        var keybindCount: Int
    }

    @discardableResult
    static func apply(_ config: ImportedConfig, keybinds: [ImportedKeybind]) throws -> Result {
        let editor = try ConfigFileEditor()
        var appearance = 0

        if let v = config.fontFamily { editor.set("font-family", v); appearance += 1 }
        if let v = config.fontSize { editor.set("font-size", trim(v)); appearance += 1 }
        if let v = config.backgroundOpacity { editor.set("background-opacity", trim(v)); appearance += 1 }
        if let v = config.paddingX { editor.set("window-padding-x", String(v)); appearance += 1 }
        if let v = config.paddingY { editor.set("window-padding-y", String(v)); appearance += 1 }
        if let v = config.cursorStyle { editor.set("cursor-style", v); appearance += 1 }

        // Colors: apply a named theme, inline colors, or reset to default.
        // Clear ALL prior color keys first so the import actually shows — an
        // existing inline `background`/`foreground` (e.g. from a previous theme
        // pick) would otherwise override whatever we write.
        if config.resetColorsToDefault || config.themeName != nil || config.hasColors {
            editor.remove("theme")
            editor.remove("background")
            editor.remove("foreground")
            editor.remove("palette")

            if !config.palette.isEmpty || config.background != nil || config.foreground != nil {
                if let bg = config.background { editor.set("background", bg); appearance += 1 }
                if let fg = config.foreground { editor.set("foreground", fg); appearance += 1 }
                for i in 0...15 where config.palette[i] != nil {
                    editor.append("palette", "\(i)=\(config.palette[i]!)")
                    appearance += 1
                }
            } else if let theme = config.themeName {
                editor.set("theme", theme); appearance += 1
            } else if config.resetColorsToDefault {
                appearance += 1   // reverted to the default theme
            }
        }

        var keybindCount = 0
        for kb in keybinds where kb.include {
            guard let action = kb.mappedAction, !action.isEmpty else { continue }
            editor.removeKeybinds(trigger: kb.trigger)   // replace, don't stack duplicates
            editor.appendKeybind("\(kb.trigger)=\(action)")
            keybindCount += 1
        }

        try editor.commit()
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        // Tell the rest of the app the config changed (object: nil = external),
        // so an open Settings window AND the sidebar Themes/Font tab re-read the
        // new theme/font/keybinds instead of showing stale values.
        NotificationCenter.default.post(name: .sarvConfigDidCommit, object: nil)
        return Result(appearanceCount: appearance, keybindCount: keybindCount)
    }

    /// Flag imported keybinds whose trigger already maps to a *different* action
    /// in SarvTerminal, so the review UI can explain before double-binding a key.
    /// A trigger already bound to the SAME action is not a conflict (importing
    /// it is a harmless no-op), so we stay quiet.
    static func markConflicts(in keybinds: [ImportedKeybind]) -> [ImportedKeybind] {
        let existing = existingBindings()   // canonical trigger → raw actions
        return keybinds.map { kb in
            var copy = kb
            guard let actions = existing[canonical(kb.trigger)], !actions.isEmpty else { return copy }
            let imported = kb.mappedAction ?? ""
            if !actions.contains(imported) {
                copy.conflict = true
                var seen = Set<String>()
                let names = actions.map(friendlyAction).filter { seen.insert($0).inserted }
                copy.conflictDetail = "already bound to \(names.joined(separator: ", "))"
            }
            return copy
        }
    }

    // MARK: - Helpers

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }

    /// Canonical form of a trigger for order-insensitive comparison
    /// (`shift+cmd+t` == `cmd+shift+t`).
    private static func canonical(_ trigger: String) -> String {
        let toks = trigger.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let key = toks.last else { return trigger.lowercased() }
        let mods = toks.dropLast().map { m -> String in
            switch m {
            case "command", "super": return "cmd"
            case "control": return "ctrl"
            case "opt", "option": return "alt"
            default: return m
            }
        }.sorted()
        return (mods + [key]).joined(separator: "+")
    }

    /// Map of canonical trigger → the raw action(s) currently bound to it,
    /// from the config-file `keybind =` lines plus app-level shortcuts.
    private static func existingBindings() -> [String: [String]] {
        var out: [String: [String]] = [:]
        if let text = try? String(contentsOf: AppPaths.ghosttyConfigFile, encoding: .utf8) {
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), line.hasPrefix("keybind") else { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if let sep = value.firstIndex(of: "=") {
                    let trig = canonical(String(value[..<sep]))
                    let action = String(value[value.index(after: sep)...])
                    out[trig, default: []].append(action)
                }
            }
        }
        for (actionID, combos) in AppKeybindStore.shared.bindings {
            for combo in combos { out[canonical(combo), default: []].append(actionID) }
        }
        return out
    }

    /// A user-facing name for a bound action. App shortcut IDs (e.g.
    /// `app:new_tab`) resolve to their label; Ghostty actions show as-is.
    private static func friendlyAction(_ raw: String) -> String {
        if raw.hasPrefix("app:"), let a = AppShortcutAction(rawValue: raw) {
            return a.label
        }
        return raw
    }
}
