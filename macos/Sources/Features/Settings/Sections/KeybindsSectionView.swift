import SwiftUI
import AppKit

/// Action-centric keybinds editor.
///
/// One row per *action*; bound shortcuts appear as chips on the right; the
/// "+" button at the end of each row opens a live key-capture sheet.
/// Multiple shortcuts per action are supported — Ghostty's binding system
/// happily accepts more than one `keybind = …` line pointing to the same
/// action.
struct KeybindsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var appStore = AppKeybindStore.shared

    /// All currently active keybinds (Ghostty defaults + user overrides),
    /// grouped by action name (parameters stripped). `loadActiveBindings`
    /// returns entries with `rawLine == ""`; we annotate user-config entries
    /// (which CAN be removed by rawLine) separately in `userRawLines`.
    @State private var bindingsByAction: [String: [KeybindEntry]] = [:]
    /// rawLine of every entry that lives in the user's config file (vs.
    /// being a built-in default). Used to decide between line-removal and
    /// writing an `unbind` override.
    @State private var userRawLines: Set<String> = []
    @State private var search: String = ""
    @State private var isLoading: Bool = false

    /// Action whose row is currently capturing a new binding (nil = no capture).
    @State private var capturingFor: KeybindAction?

    /// Set when the user just captured a combo that's already bound to a
    /// DIFFERENT action; presents a confirm-replace alert.
    @State private var pendingConflict: KeybindConflict?

    /// Set when the user clicks "Reset to defaults"; presents a confirmation.
    @State private var showResetConfirm: Bool = false

    /// Set when the user tries to assign a combo reserved by a fixed shortcut;
    /// presents a "can't be reassigned" alert.
    @State private var reservedBlock: ReservedComboBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerCard
            listCard
        }
        .onAppear(perform: reload)
        .sheet(item: $capturingFor) { action in
            KeybindCaptureSheet(
                actionLabel: action.label,
                onCapture: { combo in
                    addBinding(combo: combo, actionName: action.name)
                    capturingFor = nil
                },
                onCancel: { capturingFor = nil }
            )
        }
        .alert(item: $pendingConflict) { conflict in
            Alert(
                title: Text("Shortcut already in use"),
                message: Text("""
                    \(conflict.symbolicCombo) is currently bound to: \
                    \(conflict.conflictSummary).

                    Replace it with “\(conflict.newActionLabel)”? \
                    The existing binding will be removed.
                    """),
                primaryButton: .destructive(Text("Replace")) {
                    resolveConflictByReplacing(conflict)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Reset all keybindings to defaults?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetToDefaults()
            }
        } message: {
            Text("""
                All your custom keybindings will be removed from the config \
                file. Ghostty's built-in defaults (Copy ⌘C, Paste ⌘V, …) will \
                take effect again. This can't be undone.
                """)
        }
        .alert(item: $reservedBlock) { block in
            Alert(
                title: Text("Shortcut reserved"),
                message: Text("\(block.symbolic) is reserved for “\(block.ownerLabel)” and can't be reassigned."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure keyboard shortcuts")
                .font(.title3.weight(.semibold))
            Text("Click the + on any action to record a shortcut. Multiple shortcuts can map to the same action. Sarv Terminal's own shortcuts (command palette, local terminal) are rebindable too — e.g. you can swap ⌘T and ⌘L.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - List

    private var listCard: some View {
        SettingsCard(title: "Commands") {
            VStack(alignment: .leading, spacing: 0) {
                searchRow
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredActions, id: \.name) { action in
                            row(for: action)
                            Divider().padding(.leading, 16)
                        }
                        if filteredActions.isEmpty {
                            emptyState
                        }
                    }
                }
                .frame(minHeight: 280, maxHeight: 560)
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by action or keys (e.g. \"cmd t\")", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button {
                showResetConfirm = true
            } label: {
                Label("Reset to defaults", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.regular)
            .help("Remove all your custom keybindings; restores Ghostty's defaults.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        Text("No matches")
            .foregroundStyle(.secondary)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
    }

    private func row(for action: KeybindAction) -> some View {
        // Bindings are bucketed by full action name (including any
        // `:param` suffix), so the lookup must use the same.
        let bound = bindingsByAction[action.name] ?? []
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.label)
                Text(action.category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer(minLength: 0)

            if !action.isRebindable {
                // Fixed shortcut: static chips, no remove, no "+". Its combos
                // are reserved (can't be reassigned elsewhere).
                ForEach(action.lockedCombos, id: \.self) { combo in
                    lockedChip(combo: combo)
                }
            } else if action.isAppAction {
                // App-level shortcut(s): one or more combos backed by
                // AppKeybindStore, editable via the same capture sheet.
                ForEach(appStore.combos(forID: action.name), id: \.self) { combo in
                    appShortcutChip(combo: combo, actionID: action.name)
                }
            } else {
                ForEach(bound) { entry in
                    shortcutChip(for: entry)
                }
            }

            if action.isRebindable {
                Button {
                    capturingFor = action
                } label: {
                    Image(systemName: "plus")
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Add a shortcut for \(action.label)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Non-removable chip for a fixed (hardcoded) shortcut — shown with a lock
    /// glyph and no × button.
    private func lockedChip(combo: String) -> some View {
        let (mods, key) = KeybindParser.splitModsAndKey(combo)
        return HStack(spacing: 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 1)
            Text(mods.symbolicLabel)
                .font(.system(size: 13, weight: .medium))
            Text(KeybindKeyGlyph.display(key))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .foregroundStyle(.secondary)
        .help("Fixed shortcut — can't be changed")
    }

    /// Editable chip for an app-level shortcut (AppKeybindStore-backed).
    private func appShortcutChip(combo: String, actionID: String) -> some View {
        let (mods, key) = KeybindParser.splitModsAndKey(combo)
        return HStack(spacing: 2) {
            Text(mods.symbolicLabel)
                .font(.system(size: 13, weight: .medium))
            Text(KeybindKeyGlyph.display(key))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Button {
                appStore.removeCombo(combo, for: actionID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .help("Remove this shortcut")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func shortcutChip(for entry: KeybindEntry) -> some View {
        HStack(spacing: 2) {
            Text(entry.trigger.modifiers.symbolicLabel)
                .font(.system(size: 13, weight: .medium))
            Text(KeybindKeyGlyph.display(entry.trigger.key))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            if let chord = entry.trigger.chord {
                Text("⇢").foregroundStyle(.secondary).padding(.horizontal, 1)
                Text(chord.modifiers.symbolicLabel)
                    .font(.system(size: 13, weight: .medium))
                Text(KeybindKeyGlyph.display(chord.key))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Button {
                removeBinding(entry)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .help("Remove this shortcut")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Filtering

    private var filteredActions: [KeybindAction] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return kKeybindActions }
        return kKeybindActions.filter { action in
            if action.label.lowercased().contains(q) { return true }
            if action.name.lowercased().contains(q) { return true }
            for entry in bindingsByAction[action.name] ?? [] {
                if entry.trigger.configString.lowercased().contains(q) { return true }
            }
            return false
        }
    }

    // MARK: - Persistence

    /// Load defaults+user bindings via `+list-keybinds`, plus user-config
    /// raw lines for delete tracking. Runs the subprocess off-main so the
    /// UI stays responsive.
    private func reload() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let active = KeybindParser.loadActiveBindings()
            let userLines = KeybindParser.loadAll()
            let userLineSet = Set(userLines.map { $0.rawLine })
            // Annotate active bindings whose source we know — try to attach
            // the user's rawLine when the trigger matches.
            let userByTrigger: [String: String] = {
                var d: [String: String] = [:]
                for u in userLines {
                    d[u.trigger.configString] = u.rawLine
                }
                return d
            }()
            let annotated = active.map { entry -> KeybindEntry in
                var copy = entry
                if let raw = userByTrigger[entry.trigger.configString] {
                    copy.rawLine = raw
                }
                return copy
            }
            // Group by FULL action name (including any `:param` suffix).
            // Critical: actions that look similar but have different params
            // are conceptually distinct — `new_split:right` and
            // `new_split:down` get separate buckets so their chips don't
            // accidentally appear on the same row.
            let grouped = Dictionary(grouping: annotated) { $0.action }
            await MainActor.run {
                self.bindingsByAction = grouped
                self.userRawLines = userLineSet
                self.isLoading = false
            }
        }
    }

    /// Entry point for the capture sheet's "Save". Checks for conflicts
    /// (same combo bound to a different action) and either commits or
    /// surfaces a confirm-replace alert.
    private func addBinding(combo: String, actionName: String) {
        // Hard block: combos owned by a fixed (hardcoded) shortcut can't be
        // reused — reassigning them would leave the fixed action un-restorable
        // except via "Reset to defaults".
        if let owner = reservedComboOwnerLabel(combo) {
            let (mods, key) = KeybindParser.splitModsAndKey(combo)
            reservedBlock = ReservedComboBlock(
                symbolic: mods.symbolicLabel + KeybindKeyGlyph.display(key),
                ownerLabel: owner)
            return
        }
        let isApp = actionName.hasPrefix("app:")
        // Ghostty conflicts (skip the action's own bucket). For an app action,
        // nothing in the Ghostty config is "its own", so don't except anything.
        let ghosttyConflicts = findConflicts(
            combo: combo,
            exceptAction: isApp ? "\u{0}" : stripActionParam(actionName))
        // App-level conflicts (the same combo bound to a different app action).
        let appConflict = appStore.conflictingActionID(combo: combo, exceptID: isApp ? actionName : "")

        if !ghosttyConflicts.isEmpty || appConflict != nil {
            pendingConflict = KeybindConflict(
                combo: combo,
                newActionName: actionName,
                newActionLabel: actionLabel(for: actionName),
                conflicts: ghosttyConflicts,
                appConflictID: appConflict
            )
            return
        }
        commitBinding(combo: combo, actionName: actionName)
    }

    /// Commit a binding to its store (AppKeybindStore for app actions, the
    /// Ghostty config file otherwise).
    private func commitBinding(combo: String, actionName: String) {
        if actionName.hasPrefix("app:") {
            appStore.addCombo(combo, for: actionName)
            return
        }
        let value = "\(combo)=\(actionName)"
        do {
            let editor = try ConfigFileEditor()
            editor.appendKeybind(value)
            try editor.commit()
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            reload()
        } catch {
            NSLog("[Settings] keybind add failed: \(error.localizedDescription)")
        }
    }

    /// Find existing bindings for `combo` that map to a *different* action
    /// (we allow multiple combos to the same action, e.g. ⌘T and ⌘L both
    /// = new_tab; we don't allow ⌘T to mean two different things).
    private func findConflicts(combo: String, exceptAction: String) -> [KeybindEntry] {
        var hits: [KeybindEntry] = []
        for entries in bindingsByAction.values {
            for entry in entries {
                guard entry.trigger.configString == combo else { continue }
                if stripActionParam(entry.action) == exceptAction { continue }
                hits.append(entry)
            }
        }
        return hits
    }

    /// User confirmed they want to replace the conflicting bindings.
    private func resolveConflictByReplacing(_ conflict: KeybindConflict) {
        // Drop the conflicting combo from the other app action, if any.
        if let appID = conflict.appConflictID {
            appStore.removeCombo(conflict.combo, for: appID)
        }
        // Remove conflicting user-config Ghostty lines (built-in defaults are
        // overridden by last-write-wins).
        if !conflict.conflicts.isEmpty {
            do {
                let editor = try ConfigFileEditor()
                for entry in conflict.conflicts where !entry.rawLine.isEmpty && userRawLines.contains(entry.rawLine) {
                    editor.removeRawLine(entry.rawLine)
                }
                try editor.commit()
            } catch {
                NSLog("[Settings] keybind replace (remove) failed: \(error.localizedDescription)")
            }
        }
        // Commit the new binding (app store or Ghostty config).
        commitBinding(combo: conflict.combo, actionName: conflict.newActionName)
    }

    /// Remove every `keybind = …` line from the user's config so Ghostty's
    /// compiled-in defaults take effect.
    private func resetToDefaults() {
        do {
            let editor = try ConfigFileEditor()
            editor.removeAll(key: "keybind")
            try editor.commit()
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            reload()
        } catch {
            NSLog("[Settings] keybind reset failed: \(error.localizedDescription)")
        }
    }

    private func stripActionParam(_ action: String) -> String {
        if let colon = action.firstIndex(of: ":") {
            return String(action[..<colon])
        }
        return action
    }

    private func actionLabel(for action: String) -> String {
        if action.hasPrefix("app:"), let appAction = AppShortcutAction(rawValue: action) {
            return appAction.label
        }
        let root = stripActionParam(action)
        return kKeybindActions.first { $0.name == root }?.label ?? root
    }

    /// Remove a binding. If it came from the user's config, just delete the
    /// line. If it's a built-in default, write an `unbind` override so
    /// Ghostty stops applying it.
    private func removeBinding(_ entry: KeybindEntry) {
        do {
            let editor = try ConfigFileEditor()
            if !entry.rawLine.isEmpty && userRawLines.contains(entry.rawLine) {
                editor.removeRawLine(entry.rawLine)
            } else {
                editor.appendKeybind("\(entry.trigger.configString)=unbind")
            }
            try editor.commit()
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            reload()
        } catch {
            NSLog("[Settings] keybind delete failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - KeybindAction Identifiable

extension KeybindAction: Identifiable {
    var id: String { name }
}

// MARK: - Conflict info

/// Data for the "shortcut reserved by a fixed shortcut" hard-block alert.
struct ReservedComboBlock: Identifiable {
    let id = UUID()
    let symbolic: String
    let ownerLabel: String
}

/// Data for the "shortcut already used" confirm-replace alert.
struct KeybindConflict: Identifiable {
    let id = UUID()
    let combo: String
    let newActionName: String
    let newActionLabel: String
    let conflicts: [KeybindEntry]
    /// An app-level action (AppKeybindStore) the combo is already bound to.
    var appConflictID: String? = nil

    /// Human-readable list of the actions this combo currently triggers.
    var conflictSummary: String {
        var labels: [String] = conflicts.map { entry in
            let stripped: String = {
                if let colon = entry.action.firstIndex(of: ":") {
                    return String(entry.action[..<colon])
                }
                return entry.action
            }()
            return kKeybindActions.first { $0.name == stripped }?.label ?? stripped
        }
        if let appConflictID, let appAction = AppShortcutAction(rawValue: appConflictID) {
            labels.append(appAction.label)
        }
        return labels.joined(separator: ", ")
    }

    var symbolicCombo: String {
        // Cheap rebuild for display in the alert — reuse the parser to
        // turn "cmd+t" into "⌘T".
        let (mods, key) = KeybindParser.splitModsAndKey(
            combo.replacingOccurrences(of: ":", with: "")
        )
        return mods.symbolicLabel + key.uppercased()
    }
}
