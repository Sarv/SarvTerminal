import Foundation

/// Parser for Ghostty's `keybind = …` config lines. We do this in Swift
/// (not via the C API) because the upstream wrapper doesn't expose
/// `RepeatableKeybind` and the format is line-based + simple enough to
/// handle natively.
enum KeybindParser {

    /// Read all keybind entries from the user's config file.
    /// Returns parsed entries paired with the literal source line so we
    /// can find-and-replace on edit/delete.
    static func loadAll() -> [KeybindEntry] {
        let url = ConfigFile.url()
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var entries: [KeybindEntry] = []
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "keybind" else { continue }
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let entry = parseValue(value, rawLine: line) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Run `ghostty +list-keybinds` and parse its output. This is the
    /// authoritative list of *currently active* bindings — defaults plus
    /// user overrides combined.
    ///
    /// Runs synchronously off the main thread (call from a background task).
    /// Returns an empty array if the subprocess fails.
    static func loadActiveBindings() -> [KeybindEntry] {
        guard let binaryURL = locateBinary() else { return [] }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["+list-keybinds"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard stderr (sentry chatter)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var entries: [KeybindEntry] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "keybind" else { continue }
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Active bindings don't have a rawLine in the user's config — set
            // to empty. Removal logic distinguishes user lines (rawLine
            // populated) from defaults.
            if let entry = parseValue(value, rawLine: "") {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Locate our running app's own executable. Uses `executableURL` so this
    /// stays correct regardless of the binary's name (it differs across the
    /// release `SarvTerminal` and debug `SarvTerminalDev` builds).
    private static func locateBinary() -> URL? {
        guard let path = Bundle.main.executableURL else { return nil }
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }

    /// Parse the right-hand side of `keybind = …` into a `KeybindEntry`.
    static func parseValue(_ value: String, rawLine: String) -> KeybindEntry? {
        // The trigger/action separator is the FIRST `=` that is *followed
        // by an alpha character* (the start of an action name like
        // `new_tab`). This skips `=` characters that are the trigger key
        // itself (e.g. in `cmd+==new_tab` the second `=` is the separator).
        guard let eq = triggerActionSeparator(in: value) else { return nil }
        let triggerStr = String(value[..<eq]).trimmingCharacters(in: .whitespaces)
        let actionStr = String(value[value.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

        guard let trigger = parseTrigger(triggerStr) else { return nil }
        guard !actionStr.isEmpty else { return nil }

        return KeybindEntry(
            id: UUID(),
            rawLine: rawLine,
            trigger: trigger,
            action: actionStr
        )
    }

    private static func parseTrigger(_ input: String) -> KeybindTrigger? {
        var s = input

        // Pull off leading flags (loop because multiple flags can stack).
        var flags = KeybindFlags()
        while let colon = s.firstIndex(of: ":") {
            let prefix = String(s[..<colon]).lowercased()
            switch prefix {
            case "global": flags.global = true
            case "all": flags.all = true
            case "unconsumed": flags.unconsumed = true
            case "performable": flags.performable = true
            default:
                // Not a flag — this colon belongs to the trigger itself.
                // Bail out of the flag-extraction loop.
                break
            }
            // Only advance if we recognized this as a flag.
            let recognized = ["global", "all", "unconsumed", "performable"].contains(prefix)
            if !recognized { break }
            s = String(s[s.index(after: colon)...])
        }

        // Chord splitting: "ctrl+a>n" -> ["ctrl+a", "n"].
        let parts = s.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let mainStr = parts.first else { return nil }
        let (mods, key) = splitModsAndKey(mainStr)
        guard !key.isEmpty else { return nil }

        var chord: ChordContinuation?
        if parts.count == 2 {
            let (chMods, chKey) = splitModsAndKey(parts[1])
            if !chKey.isEmpty {
                chord = ChordContinuation(modifiers: chMods, key: chKey)
            }
        }

        return KeybindTrigger(
            modifiers: mods,
            key: key,
            chord: chord,
            flags: flags
        )
    }

    /// Split "ctrl+shift+a" into (Modifiers, "a"). Modifiers can appear
    /// in any order; case-insensitive. Supports `+` as the literal key
    /// (e.g. "cmd++") — an empty trailing token means the key is `+`.
    static func splitModsAndKey(_ input: String) -> (KeybindModifiers, String) {
        // Keep empty subsequences so a trailing `+` (= literal `+` key)
        // isn't silently dropped.
        let rawTokens = input.split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !rawTokens.isEmpty else { return ([], "") }

        // Special case: "cmd++" → rawTokens = ["cmd", "", ""]. The literal
        // `+` key is captured as an empty FINAL token; we treat the second-
        // to-last `+` as the modifier separator and the last as the key.
        var tokens = rawTokens
        var key = ""
        if tokens.last == "" {
            // Empty last token means the input ended in `+`. That trailing
            // `+` is the key. Remove the empty marker; we'll set key = "+".
            tokens.removeLast()
            key = "+"
        }

        var mods = KeybindModifiers()
        for (i, token) in tokens.enumerated() {
            if token.isEmpty { continue }  // stray empty between modifiers — ignore
            switch token.lowercased() {
            case "ctrl": mods.insert(.ctrl)
            // On macOS, `super` and `cmd` are the same physical key.
            case "cmd", "command", "super": mods.insert(.cmd)
            case "shift": mods.insert(.shift)
            case "alt", "opt", "option": mods.insert(.opt)
            default:
                // Anything we don't recognize is the key — only valid as the
                // last token. (If `+` was already detected above, this stays
                // unchanged.)
                if i == tokens.count - 1 && key.isEmpty {
                    key = token
                }
            }
        }
        return (mods, key)
    }

    /// Find the position of the `=` separating trigger from action in a
    /// keybind value. Action names are alphanumeric_with_underscores so
    /// we pick the first `=` whose successor is alpha (or `_`).
    static func triggerActionSeparator(in value: String) -> String.Index? {
        var idx = value.startIndex
        while idx < value.endIndex {
            if value[idx] == "=" {
                let next = value.index(after: idx)
                if next < value.endIndex {
                    let c = value[next]
                    if c.isLetter || c == "_" {
                        return idx
                    }
                }
            }
            idx = value.index(after: idx)
        }
        return nil
    }
}

/// Path resolver for `~/.config/ghostty/config` honoring `XDG_CONFIG_HOME`.
enum ConfigFile {
    static func url() -> URL {
        let env = ProcessInfo.processInfo.environment
        let baseDir: URL = {
            if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
                return URL(fileURLWithPath: xdg)
            }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        }()
        return baseDir.appendingPathComponent("ghostty/config")
    }
}
