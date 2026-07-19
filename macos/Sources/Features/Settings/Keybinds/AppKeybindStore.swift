import Foundation
import AppKit

/// SarvTerminal app-level keyboard shortcuts that are handled by the app
/// (AppDelegate's key-event monitor) rather than by the Ghostty config —
/// because there are no Ghostty actions for "open command palette" or "open
/// local terminal tab".
///
/// Persisted in UserDefaults so they're rebindable from Settings → Keybinds,
/// just like Ghostty keybinds. Each action can have MULTIPLE combos (e.g. both
/// ⌘T and ⌘L → command palette). Combos use Ghostty config format ("cmd+t").
enum AppShortcutAction: String, CaseIterable {
    case commandPalette = "app:command_palette"
    case newLocalTerminal = "app:new_local_terminal"
    case splitRight = "app:split_right"
    case splitDown = "app:split_down"
    case reopenClosedTab = "app:reopen_closed_tab"
    case showVaults = "app:show_vaults"
    case showSFTP = "app:show_sftp"
    case saveSession = "app:save_session"
    case toggleScratchpad = "app:toggle_scratchpad"

    var label: String {
        switch self {
        case .commandPalette: return "New tab / command palette"
        case .newLocalTerminal: return "New Local Terminal Tab"
        case .splitRight: return "Split right (choose target)"
        case .splitDown: return "Split down (choose target)"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .showVaults: return "Show Vaults"
        case .showSFTP: return "Show SFTP"
        case .saveSession: return "Save Session (active tab)"
        case .toggleScratchpad: return "Toggle Scratchpad"
        }
    }

    /// Default combo(s) for this action. The command palette opens with both
    /// ⌘T (new tab) and ⌘P (palette / Termius-style quick-connect search). We
    /// deliberately avoid ⌘K — that's a Ghostty default (clear screen).
    var defaultCombos: [String] {
        switch self {
        case .commandPalette: return ["cmd+t", "cmd+p"]
        case .newLocalTerminal: return ["cmd+l"]
        case .splitRight: return ["cmd+d"]
        case .splitDown: return ["cmd+shift+d"]
        case .reopenClosedTab: return ["cmd+shift+t"]
        case .showVaults: return ["cmd+shift+v"]
        case .showSFTP: return ["cmd+shift+s"]
        case .saveSession: return ["cmd+s"]
        case .toggleScratchpad: return ["cmd+shift+e"]
        }
    }
}

final class AppKeybindStore: ObservableObject {
    static let shared = AppKeybindStore()

    /// actionID -> combos (Ghostty config format, e.g. "cmd+t"). An action may
    /// have multiple combos; an empty/absent entry means it's unbound.
    @Published private(set) var bindings: [String: [String]] = [:]

    private let defaultsKey = "SarvAppKeybinds"

    private init() {
        bindings = Self.loadStored()
        // Seed defaults for any action with no binding yet (first run, or a
        // newly added action). Only fills gaps — never clobbers user choices.
        var didSeed = false
        for action in AppShortcutAction.allCases where (bindings[action.rawValue]?.isEmpty ?? true) {
            bindings[action.rawValue] = action.defaultCombos
            didSeed = true
        }
        if didSeed { persist() }
        migrateCommandPalettePaletteKey()
        migrateSFTPKey()
    }

    /// One-time migration: SFTP defaulted to ⌘⇧F in an earlier build; move it to
    /// ⌘⇧S for existing installs. The flag prevents re-applying after the user
    /// changes it themselves.
    private func migrateSFTPKey() {
        let flag = "SarvAppKeybinds.sftpKey.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let id = AppShortcutAction.showSFTP.rawValue
        removeCombo("cmd+shift+f", for: id)
        let combos = bindings[id] ?? []
        let hasS = combos.contains { KeybindParser.splitModsAndKey($0) == KeybindParser.splitModsAndKey("cmd+shift+s") }
        if !hasS { addCombo("cmd+shift+s", for: id) }
    }

    /// One-time migration: an earlier build defaulted ⌘K → command palette,
    /// which shadowed Ghostty's ⌘K (clear screen). Give ⌘K back to Ghostty and
    /// use ⌘P (palette) instead — ⌘P is not a Ghostty default. The flag stops
    /// this from re-adding a combo the user later removes on purpose.
    private func migrateCommandPalettePaletteKey() {
        let flag = "SarvAppKeybinds.paletteKey.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let id = AppShortcutAction.commandPalette.rawValue
        removeCombo("cmd+k", for: id)   // restore ⌘K → Ghostty clear screen
        let combos = bindings[id] ?? []
        let hasCmdP = combos.contains { KeybindParser.splitModsAndKey($0) == KeybindParser.splitModsAndKey("cmd+p") }
        if !hasCmdP { addCombo("cmd+p", for: id) }
    }

    /// Load + migrate from the old single-combo format if present.
    private static func loadStored() -> [String: [String]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "SarvAppKeybinds") else { return [:] }
        if let arrays = raw as? [String: [String]] { return arrays }
        if let singles = raw as? [String: String] { return singles.mapValues { [$0] } }
        return [:]
    }

    func combos(forID id: String) -> [String] { bindings[id] ?? [] }

    /// Add `combo` to `actionID` (multiple combos per action are allowed).
    /// Enforces global uniqueness: the combo is removed from every OTHER action
    /// first, so a combo only ever triggers one action.
    func addCombo(_ combo: String, for actionID: String) {
        let target = KeybindParser.splitModsAndKey(combo)
        for (id, combos) in bindings where id != actionID {
            bindings[id] = combos.filter { existing in
                let cur = KeybindParser.splitModsAndKey(existing)
                return !(cur.0 == target.0 && cur.1 == target.1)
            }
        }
        var mine = bindings[actionID] ?? []
        if !mine.contains(where: { let c = KeybindParser.splitModsAndKey($0); return c.0 == target.0 && c.1 == target.1 }) {
            mine.append(combo)
        }
        bindings[actionID] = mine
        persist()
    }

    /// Remove a specific combo from an action.
    func removeCombo(_ combo: String, for actionID: String) {
        let target = KeybindParser.splitModsAndKey(combo)
        bindings[actionID] = (bindings[actionID] ?? []).filter { existing in
            let cur = KeybindParser.splitModsAndKey(existing)
            return !(cur.0 == target.0 && cur.1 == target.1)
        }
        persist()
    }

    /// The app action bound to the given key event, if any.
    func action(matching event: NSEvent) -> AppShortcutAction? {
        let eventMods = Self.modifiers(from: event)
        guard !eventMods.isEmpty else { return nil }
        let eventKey = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard !eventKey.isEmpty else { return nil }
        for (id, combos) in bindings {
            for combo in combos {
                let (mods, key) = KeybindParser.splitModsAndKey(combo)
                if mods == eventMods && key == eventKey {
                    return AppShortcutAction(rawValue: id)
                }
            }
        }
        return nil
    }

    /// An app action (other than `exceptID`) already bound to `combo`, if any.
    func conflictingActionID(combo: String, exceptID: String) -> String? {
        let (targetMods, targetKey) = KeybindParser.splitModsAndKey(combo)
        for (id, combos) in bindings where id != exceptID {
            for existing in combos {
                let (mods, key) = KeybindParser.splitModsAndKey(existing)
                if mods == targetMods && key == targetKey { return id }
            }
        }
        return nil
    }

    private static func modifiers(from event: NSEvent) -> KeybindModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: KeybindModifiers = []
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.command) { mods.insert(.cmd) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.opt) }
        return mods
    }

    private func persist() {
        UserDefaults.standard.set(bindings, forKey: defaultsKey)
    }
}
