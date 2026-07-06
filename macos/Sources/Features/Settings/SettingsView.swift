import SwiftUI
import AppKit
import Combine

/// Shared state for the Settings UI. Owned by `SettingsContainerViewController`
/// and observed by the sidebar, detail, and footer SwiftUI views — which now
/// live in separate `NSHostingController`s inside an `NSSplitViewController`.
///
/// **Live preview semantics:** every change to `appearance` is auto-written to
/// disk (debounced ~150ms) and triggers a Ghostty config reload. The user sees
/// the terminal update as they drag sliders / pick colors. The Save/Revert
/// buttons retain meaning:
///
/// - `savedAppearance` = "confirmed baseline" — Save updates it.
/// - `lastWrittenAppearance` = "what's on disk right now" — used to compute the
///   minimal diff to write on each debounced commit.
///
/// `Revert` restores `appearance` to `savedAppearance`; the debounce
/// subscription then writes the restored values back. Closing the Settings
/// window without explicitly clicking Save leaves live-preview changes on disk.
final class SettingsViewModel: ObservableObject {
    @Published var selectedSection: SettingsSection? = .general
    @Published var searchText: String = ""

    /// Per-section editable form state. Section views bind directly to
    /// fields inside these forms.
    @Published var appearance: AppearanceForm
    @Published var font: FontForm
    @Published var cursor: CursorForm
    @Published var general: GeneralForm
    @Published var window: WindowForm
    @Published var tabs: TabsForm
    @Published var shellIntegration: ShellIntegrationForm

    /// Snapshots taken at Settings-window open (and after each explicit Save).
    /// Drives the dirty indicator and what Revert restores to.
    private var savedAppearance: AppearanceForm
    private var savedFont: FontForm
    private var savedCursor: CursorForm
    private var savedGeneral: GeneralForm
    private var savedWindow: WindowForm
    private var savedTabs: TabsForm
    private var savedShellIntegration: ShellIntegrationForm

    /// What's currently on disk. Updated by every debounced live-preview write.
    /// The serializer diffs against this so we never re-write unchanged lines.
    private var lastWrittenAppearance: AppearanceForm
    private var lastWrittenFont: FontForm
    private var lastWrittenCursor: CursorForm
    private var lastWrittenGeneral: GeneralForm
    private var lastWrittenWindow: WindowForm
    private var lastWrittenTabs: TabsForm
    private var lastWrittenShellIntegration: ShellIntegrationForm

    private var subscriptions = Set<AnyCancellable>()

    init() {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let initialAppearance = AppearanceForm(loadedFrom: config)
        let initialFont = FontForm(loadedFrom: config)
        let initialCursor = CursorForm(loadedFrom: config)
        let initialGeneral = GeneralForm(loadedFrom: config)
        let initialWindow = WindowForm(loadedFrom: config)
        let initialTabs = TabsForm(loadedFrom: config)
        let initialShellInt = ShellIntegrationForm(loadedFrom: config)

        self.appearance = initialAppearance
        self.savedAppearance = initialAppearance
        self.lastWrittenAppearance = initialAppearance

        self.font = initialFont
        self.savedFont = initialFont
        self.lastWrittenFont = initialFont

        self.cursor = initialCursor
        self.savedCursor = initialCursor
        self.lastWrittenCursor = initialCursor

        self.general = initialGeneral
        self.savedGeneral = initialGeneral
        self.lastWrittenGeneral = initialGeneral

        self.window = initialWindow
        self.savedWindow = initialWindow
        self.lastWrittenWindow = initialWindow

        self.tabs = initialTabs
        self.savedTabs = initialTabs
        self.lastWrittenTabs = initialTabs

        self.shellIntegration = initialShellInt
        self.savedShellIntegration = initialShellInt
        self.lastWrittenShellIntegration = initialShellInt

        // Live preview: one debounced subscription per form.
        wireLivePreview($appearance.eraseToAnyPublisher())
        wireLivePreview($font.eraseToAnyPublisher())
        wireLivePreview($cursor.eraseToAnyPublisher())
        wireLivePreview($general.eraseToAnyPublisher())
        wireLivePreview($window.eraseToAnyPublisher())
        wireLivePreview($tabs.eraseToAnyPublisher())
        wireLivePreview($shellIntegration.eraseToAnyPublisher())

        // After a sync Pull overwrites config/UserDefaults on disk, re-read so
        // the open Settings window reflects the pulled values immediately.
        NotificationCenter.default.addObserver(
            forName: .sarvSyncDidPull, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadFromDisk()
        }

        // Same when anything ELSE commits the config (e.g. the command
        // sidebar's theme/font tab) — otherwise an open Settings window keeps
        // showing the stale theme. Our own commits post with `object: self`,
        // so skip those to avoid rebuilding the forms mid-edit.
        NotificationCenter.default.addObserver(
            forName: .sarvConfigDidCommit, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? SettingsViewModel !== self else { return }
            self.reloadFromDisk()
        }
    }

    /// Rebuild every form from what's currently on disk (config + UserDefaults)
    /// and re-baseline. Used after a sync Pull, since forms are otherwise only
    /// read at init.
    func reloadFromDisk() {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        appearance = AppearanceForm(loadedFrom: config)
        font = FontForm(loadedFrom: config)
        cursor = CursorForm(loadedFrom: config)
        general = GeneralForm(loadedFrom: config)
        window = WindowForm(loadedFrom: config)
        tabs = TabsForm(loadedFrom: config)
        shellIntegration = ShellIntegrationForm(loadedFrom: config)
        captureBaselines()
    }

    /// Sets up the standard debounce subscription that writes the form to
    /// disk after a short pause.
    private func wireLivePreview<Form: Equatable>(_ publisher: AnyPublisher<Form, Never>) {
        publisher
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.commitToDisk() }
            .store(in: &subscriptions)
    }

    /// Snapshot every form's current values as the baseline that Revert
    /// returns to. Called when the Settings window opens, so "Revert" means
    /// "undo the changes I made in this visit".
    func captureBaselines() {
        savedAppearance = appearance
        savedFont = font
        savedCursor = cursor
        savedGeneral = general
        savedWindow = window
        savedTabs = tabs
        savedShellIntegration = shellIntegration
        SFTPSettings.shared.captureBaseline()
    }

    /// Whether a section participates in the footer Revert / Reset actions.
    /// Keybinds and Advanced manage their own editing surfaces.
    func supportsFooterActions(_ section: SettingsSection) -> Bool {
        switch section {
        case .keybinds, .advanced, .sync, .notifications: return false
        default: return true
        }
    }

    /// True when the given section differs from its captured baseline.
    func isDirty(section: SettingsSection) -> Bool {
        switch section {
        case .general: return general != savedGeneral
        case .appearance: return appearance != savedAppearance
        case .font: return font != savedFont
        case .cursor: return cursor != savedCursor
        case .window: return window != savedWindow
        case .tabs: return tabs != savedTabs
        case .shellIntegration: return shellIntegration != savedShellIntegration
        case .sftp: return SFTPSettings.shared.isDirty
        case .keybinds, .advanced, .sync, .notifications: return false
        }
    }

    var filteredSections: [SettingsSection] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SettingsSection.visibleSections }
        return SettingsSection.visibleSections.filter { $0.matchesSearch(q) }
    }

    /// True when the user is actively searching.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Individual settings matching the query, across all visible sections.
    /// Drives the search results list in the sidebar.
    var searchResults: [SettingsSearchEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return SettingsSearchEntry.all.filter {
            SettingsSection.visibleSections.contains($0.section) && $0.matches(q)
        }
    }

    /// Last error from a write attempt, surfaced in the UI.
    @Published var lastSaveError: String?

    /// Drives the transient green "Saved automatically" confirmation in the
    /// footer. Set true on every successful write, then cleared after a beat.
    @Published var showSavedFlash: Bool = false
    private var flashWorkItem: DispatchWorkItem?

    /// Flash the green auto-saved confirmation. Called after any change lands
    /// on disk (config sections) or in UserDefaults (SFTP).
    func flashSaved() {
        showSavedFlash = true
        flashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showSavedFlash = false }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Undo the changes made to one section since the window opened, restoring
    /// it to its captured baseline. The debounce subscriptions pick up the
    /// assignment and write the restored values to disk.
    func revert(section: SettingsSection) {
        switch section {
        case .general: general = savedGeneral
        case .appearance: appearance = savedAppearance
        case .font: font = savedFont
        case .cursor: cursor = savedCursor
        case .window: window = savedWindow
        case .tabs: tabs = savedTabs
        case .shellIntegration: shellIntegration = savedShellIntegration
        case .sftp: SFTPSettings.shared.revertToBaseline()
        case .keybinds, .advanced, .sync, .notifications: break
        }
        lastSaveError = nil
    }

    /// Reset one section to its factory defaults. Live preview writes the
    /// defaults to disk just like any other edit.
    func resetToDefault(section: SettingsSection) {
        switch section {
        case .general: general = GeneralForm(loadedFrom: nil)
        case .appearance: appearance = AppearanceForm(loadedFrom: nil)
        case .font: font = FontForm(loadedFrom: nil)
        case .cursor: cursor = CursorForm(loadedFrom: nil)
        case .window: window = WindowForm(loadedFrom: nil)
        case .tabs: tabs = TabsForm(loadedFrom: nil)
        case .shellIntegration: shellIntegration = ShellIntegrationForm(loadedFrom: nil)
        case .sftp: SFTPSettings.shared.resetToDefaults()
        case .keybinds, .advanced, .sync, .notifications: break
        }
        lastSaveError = nil
    }

    /// Called by the debounce subscriptions after any change to a form.
    /// Writes the minimal diff against what's currently on disk, then asks
    /// Ghostty to reload.
    private func commitToDisk() {
        do {
            let editor = try ConfigFileEditor()
            applyAppearanceDiff(editor: editor)
            applyFontDiff(editor: editor)
            applyCursorDiff(editor: editor)
            applyGeneralDiff(editor: editor)
            applyWindowDiff(editor: editor)
            applyTabsDiff(editor: editor)
            applyShellIntegrationDiff(editor: editor)
            try editor.commit()
            // Mirror the render-relevant facts to the runtime store so the
            // terminal window can draw the window-level image in shared mode,
            // and persist the shared pane opacity for the next launch.
            BackgroundDisplayStore.shared.update(
                useShared: appearance.backgroundDisplayShared,
                imagePath: appearance.backgroundImagePath,
                imageVisibility: appearance.sharedImageVisibility
            )
            lastWrittenAppearance = appearance
            lastWrittenFont = font
            lastWrittenCursor = cursor
            lastWrittenGeneral = general
            lastWrittenWindow = window
            lastWrittenTabs = tabs
            lastWrittenShellIntegration = shellIntegration
            lastSaveError = nil
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            flashSaved()
            // `object: self` marks this as OUR commit so the reload observer
            // above ignores it (external commits arrive with a different object).
            NotificationCenter.default.post(name: .sarvConfigDidCommit, object: self)
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    /// Diff each appearance field against what's already on disk. Only fields
    /// that changed get serialized; everything else (including user-managed
    /// config lines we don't manage) is left untouched.
    private func applyAppearanceDiff(editor: ConfigFileEditor) {
        let cur = appearance
        let was = lastWrittenAppearance

        if cur.backgroundColor != was.backgroundColor {
            editor.set("background", ColorSwatchPicker.hexString(from: cur.backgroundColor))
        }
        // Effective terminal background opacity: in shared mode the panes are
        // made translucent so the window-level image shows through. We must NOT
        // use 0.0 — a fully transparent window stops the tab bar from rendering
        // — so we keep a moderate value and let the image's own opacity
        // (sharedImageVisibility) be the brightness control. Otherwise the
        // user's chosen opacity applies.
        let sharedPaneOpacity = BackgroundDisplayStore.sharedPaneOpacity
        let curOpacity = cur.backgroundDisplayShared ? sharedPaneOpacity : cur.backgroundOpacity
        let wasOpacity = was.backgroundDisplayShared ? sharedPaneOpacity : was.backgroundOpacity
        if curOpacity != wasOpacity {
            editor.set("background-opacity", String(format: "%.2f", curOpacity))
        }
        if cur.backgroundBlur != was.backgroundBlur {
            editor.set("background-blur", cur.backgroundBlur.configValue)
        }
        if cur.foregroundColor != was.foregroundColor {
            editor.set("foreground", ColorSwatchPicker.hexString(from: cur.foregroundColor))
        }

        // Optional colors — when toggled off, remove the line so Ghostty
        // falls back to its default. When toggled on, write the chosen color.
        diffOptionalColor("cursor-color",
                          curOn: cur.useCursorColor, curColor: cur.cursorColor,
                          wasOn: was.useCursorColor, wasColor: was.cursorColor,
                          editor: editor)
        diffOptionalColor("selection-foreground",
                          curOn: cur.useSelectionForeground, curColor: cur.selectionForeground,
                          wasOn: was.useSelectionForeground, wasColor: was.selectionForeground,
                          editor: editor)
        diffOptionalColor("selection-background",
                          curOn: cur.useSelectionBackground, curColor: cur.selectionBackground,
                          wasOn: was.useSelectionBackground, wasColor: was.selectionBackground,
                          editor: editor)
        diffOptionalColor("bold-color",
                          curOn: cur.useBoldColor, curColor: cur.boldColor,
                          wasOn: was.useBoldColor, wasColor: was.boldColor,
                          editor: editor)

        if cur.windowTheme != was.windowTheme {
            editor.set("window-theme", cur.windowTheme.rawValue)
        }
        if cur.themeName != was.themeName {
            if cur.themeName.isEmpty {
                editor.remove("theme")
            } else {
                editor.set("theme", cur.themeName)
            }
        }

        // Background image: empty string = "no image", which we represent
        // by REMOVING any existing background-image* lines so they don't
        // sit in the config as dead values. In SHARED mode the config carries
        // no `background-image` at all — the image is drawn at the window level
        // by VaultsRootView — so the effective value is always empty there.
        let curImage = cur.backgroundDisplayShared ? "" : cur.backgroundImagePath
        let wasImage = was.backgroundDisplayShared ? "" : was.backgroundImagePath
        if curImage != wasImage {
            if curImage.isEmpty {
                editor.remove("background-image")
            } else {
                editor.set("background-image", curImage)
            }
        }
        if cur.backgroundImageOpacity != was.backgroundImageOpacity {
            editor.set("background-image-opacity",
                       String(format: "%.2f", cur.backgroundImageOpacity))
        }
        if cur.backgroundImageFit != was.backgroundImageFit {
            editor.set("background-image-fit", cur.backgroundImageFit.rawValue)
        }
        if cur.backgroundImagePosition != was.backgroundImagePosition {
            editor.set("background-image-position", cur.backgroundImagePosition.rawValue)
        }
        if cur.backgroundImageRepeat != was.backgroundImageRepeat {
            editor.set("background-image-repeat", cur.backgroundImageRepeat ? "true" : "false")
        }
    }

    /// Diff each font field. Same diff-against-disk pattern.
    private func applyFontDiff(editor: ConfigFileEditor) {
        let cur = font
        let was = lastWrittenFont

        if cur.family != was.family {
            if cur.family.isEmpty {
                editor.remove("font-family")
            } else {
                editor.set("font-family", cur.family)
            }
        }
        if cur.size != was.size {
            editor.set("font-size", String(format: "%g", cur.size))
        }
        if cur.feature != was.feature {
            if cur.feature.isEmpty {
                editor.remove("font-feature")
            } else {
                editor.set("font-feature", cur.feature)
            }
        }
        if cur.thicken != was.thicken {
            editor.set("font-thicken", cur.thicken ? "true" : "false")
        }
        diffOptionalString("adjust-cell-width", cur: cur.adjustCellWidth, was: was.adjustCellWidth, editor: editor)
        diffOptionalString("adjust-cell-height", cur: cur.adjustCellHeight, was: was.adjustCellHeight, editor: editor)
    }

    /// Write a string key when non-empty, remove it when cleared.
    private func diffOptionalString(_ key: String, cur: String, was: String, editor: ConfigFileEditor) {
        guard cur != was else { return }
        if cur.trimmingCharacters(in: .whitespaces).isEmpty {
            editor.remove(key)
        } else {
            editor.set(key, cur)
        }
    }

    /// Diff cursor fields against what's currently on disk.
    private func applyCursorDiff(editor: ConfigFileEditor) {
        let cur = cursor
        let was = lastWrittenCursor

        if cur.style != was.style {
            editor.set("cursor-style", cur.style.rawValue)
        }
        if cur.blink != was.blink {
            switch cur.blink {
            case .systemDefault: editor.remove("cursor-style-blink")
            case .on: editor.set("cursor-style-blink", "true")
            case .off: editor.set("cursor-style-blink", "false")
            }
        }
        diffOptionalColor("cursor-text",
                          curOn: cur.useTextColor, curColor: cur.textColor,
                          wasOn: was.useTextColor, wasColor: was.textColor,
                          editor: editor)
        if cur.opacity != was.opacity {
            editor.set("cursor-opacity", String(format: "%.2f", cur.opacity))
        }
        if cur.clickToMove != was.clickToMove {
            editor.set("cursor-click-to-move", cur.clickToMove ? "true" : "false")
        }
    }

    private func applyGeneralDiff(editor: ConfigFileEditor) {
        let cur = general
        let was = lastWrittenGeneral

        if cur.command != was.command {
            if cur.command.isEmpty { editor.remove("command") }
            else { editor.set("command", cur.command) }
        }
        if cur.confirmClose != was.confirmClose {
            editor.set("confirm-close-surface", cur.confirmClose.rawValue)
        }
        if cur.quitAfterLastWindowClosed != was.quitAfterLastWindowClosed {
            editor.set("quit-after-last-window-closed",
                       cur.quitAfterLastWindowClosed ? "true" : "false")
        }
        if cur.scrollbackLimitMB != was.scrollbackLimitMB {
            let bytes = Int(cur.scrollbackLimitMB * 1_000_000)
            editor.set("scrollback-limit", String(bytes))
        }
        if cur.mouseHideWhileTyping != was.mouseHideWhileTyping {
            editor.set("mouse-hide-while-typing",
                       cur.mouseHideWhileTyping ? "true" : "false")
        }
        if cur.showProgressBar != was.showProgressBar {
            editor.set("progress-style", cur.showProgressBar ? "true" : "false")
        }
        if cur.focusFollowsMouse != was.focusFollowsMouse {
            editor.set("focus-follows-mouse",
                       cur.focusFollowsMouse ? "true" : "false")
        }
        if cur.copyOnSelect != was.copyOnSelect {
            editor.set("copy-on-select", cur.copyOnSelect.rawValue)
        }
        if cur.clipboardRead != was.clipboardRead {
            editor.set("clipboard-read", cur.clipboardRead.rawValue)
        }
        if cur.clipboardWrite != was.clipboardWrite {
            editor.set("clipboard-write", cur.clipboardWrite.rawValue)
        }
        diffOptionalString("working-directory", cur: cur.workingDirectory, was: was.workingDirectory, editor: editor)
        if cur.mouseScrollMultiplier != was.mouseScrollMultiplier {
            editor.set("mouse-scroll-multiplier", String(format: "%g", cur.mouseScrollMultiplier))
        }
        if cur.clipboardPasteProtection != was.clipboardPasteProtection {
            editor.set("clipboard-paste-protection", cur.clipboardPasteProtection ? "true" : "false")
        }
        if cur.linkURL != was.linkURL {
            editor.set("link-url", cur.linkURL ? "true" : "false")
        }
    }

    private func applyWindowDiff(editor: ConfigFileEditor) {
        let cur = window
        let was = lastWrittenWindow

        if cur.decoration != was.decoration {
            editor.set("window-decoration", cur.decoration.rawValue)
        }
        if cur.saveState != was.saveState {
            editor.set("window-save-state", cur.saveState.rawValue)
        }
        if cur.stepResize != was.stepResize {
            editor.set("window-step-resize", cur.stepResize ? "true" : "false")
        }
        if cur.paddingBalance != was.paddingBalance {
            editor.set("window-padding-balance", cur.paddingBalance ? "true" : "false")
        }
        diffOptionalString("window-padding-x", cur: cur.paddingX, was: was.paddingX, editor: editor)
        diffOptionalString("window-padding-y", cur: cur.paddingY, was: was.paddingY, editor: editor)
    }

    private func applyTabsDiff(editor: ConfigFileEditor) {
        let cur = tabs
        let was = lastWrittenTabs

        if cur.titlebarStyle != was.titlebarStyle {
            editor.set("macos-titlebar-style", cur.titlebarStyle.rawValue)
        }
        if cur.titlebarProxyIcon != was.titlebarProxyIcon {
            editor.set("macos-titlebar-proxy-icon", cur.titlebarProxyIcon.rawValue)
        }
        if cur.newTabPosition != was.newTabPosition {
            editor.set("window-new-tab-position", cur.newTabPosition.rawValue)
        }
    }

    private func applyShellIntegrationDiff(editor: ConfigFileEditor) {
        let cur = shellIntegration
        let was = lastWrittenShellIntegration

        if cur.integration != was.integration {
            editor.set("shell-integration", cur.integration.rawValue)
        }
        if cur.features != was.features {
            if cur.features.isEmpty {
                editor.remove("shell-integration-features")
            } else {
                editor.set("shell-integration-features", cur.features)
            }
        }
    }

    /// Helper: serialize an optional color toggle to the editor.
    private func diffOptionalColor(
        _ key: String,
        curOn: Bool, curColor: Color,
        wasOn: Bool, wasColor: Color,
        editor: ConfigFileEditor
    ) {
        let changed = curOn != wasOn || (curOn && curColor != wasColor)
        guard changed else { return }
        if curOn {
            editor.set(key, ColorSwatchPicker.hexString(from: curColor))
        } else {
            editor.remove(key)
        }
    }
}

// MARK: - Form models

/// Editable Appearance state. Equatable so the view model can detect dirtiness
/// against a saved snapshot via `==`.
struct AppearanceForm: Equatable {
    // Background
    var backgroundColor: Color
    var backgroundOpacity: Double
    var backgroundBlur: BackgroundBlurOption

    // Colors
    var foregroundColor: Color
    var useCursorColor: Bool
    var cursorColor: Color
    var useSelectionForeground: Bool
    var selectionForeground: Color
    var useSelectionBackground: Bool
    var selectionBackground: Color
    var useBoldColor: Bool
    var boldColor: Color

    // Background image
    var backgroundImagePath: String        // empty string = no image
    var backgroundImageOpacity: Double
    var backgroundImageFit: BackgroundImageFit
    var backgroundImagePosition: BackgroundImagePosition
    var backgroundImageRepeat: Bool

    // Background display mode (Sarv): per-pane = Ghostty draws the image on each
    // surface; shared = one image at the window level behind transparent panes.
    var backgroundDisplayShared: Bool
    /// How visible the shared image is (0…1). Applied as the window image's
    /// opacity; in shared mode the panes are made fully transparent so the
    /// image shows through cleanly.
    var sharedImageVisibility: Double

    // Theme
    var windowTheme: WindowThemeOption
    var themeName: String

    /// Builds a form from current live config, falling back to sensible
    /// defaults if no config is available (e.g. during previews).
    init(loadedFrom config: Ghostty.Config?) {
        let defaultBg = Color(red: 0.12, green: 0.12, blue: 0.13)
        let defaultFg = Color.white

        self.backgroundColor = config?.backgroundColor ?? defaultBg
        self.backgroundOpacity = config?.backgroundOpacity ?? 1.0
        self.backgroundBlur = BackgroundBlurOption(config?.backgroundBlur)

        self.foregroundColor = config?.foregroundColor ?? defaultFg

        let cursor = config?.cursorColor
        self.useCursorColor = cursor != nil
        self.cursorColor = cursor ?? defaultFg

        let selFg = config?.selectionForeground
        self.useSelectionForeground = selFg != nil
        self.selectionForeground = selFg ?? defaultBg

        let selBg = config?.selectionBackground
        self.useSelectionBackground = selBg != nil
        self.selectionBackground = selBg ?? defaultFg

        // `bold-color` may be a hex color or the literal "bright". We expose it
        // as an optional color; a non-hex value (e.g. "bright") set in the file
        // is preserved unless the user edits this control.
        let bold = config?.boldColor ?? ""
        self.useBoldColor = !bold.isEmpty
        self.boldColor = ColorSwatchPicker.color(fromHex: bold) ?? defaultFg

        self.backgroundImageOpacity = config?.backgroundImageOpacity ?? 1.0
        self.backgroundImageFit = BackgroundImageFit(rawValue: config?.backgroundImageFit ?? "contain") ?? .contain
        self.backgroundImagePosition = BackgroundImagePosition(rawValue: config?.backgroundImagePosition ?? "center") ?? .center
        self.backgroundImageRepeat = config?.backgroundImageRepeat ?? false

        // Background display mode. In shared mode the config carries no
        // `background-image` (it's drawn at the window level instead) and
        // `background-opacity` is the *pane* opacity — so we source the image
        // path from UserDefaults and split the opacity into its own field.
        let shared = UserDefaults.standard.bool(forKey: "SarvBgShared")
        self.backgroundDisplayShared = shared
        let storedVisibility = UserDefaults.standard.double(forKey: "SarvBgVisibility")
        self.sharedImageVisibility = storedVisibility == 0 ? 0.45 : storedVisibility
        if shared {
            // In shared mode the config has no `background-image` (drawn at the
            // window level) and `background-opacity` is forced to 0 (transparent
            // panes), so source the image path from UserDefaults and keep a sane
            // per-pane opacity default for when the user switches back.
            self.backgroundImagePath = UserDefaults.standard.string(forKey: "SarvBgImagePath") ?? ""
            self.backgroundOpacity = 1.0
        } else {
            self.backgroundImagePath = config?.backgroundImage ?? ""
        }

        self.windowTheme = WindowThemeOption(rawValue: config?.windowTheme ?? "system") ?? .system
        self.themeName = config?.themeName ?? ""
    }

    var hasBackgroundImage: Bool {
        !backgroundImagePath.isEmpty
    }
}

/// Editable Font state.
struct FontForm: Equatable {
    var family: String
    var size: Double
    var feature: String
    var thicken: Bool
    var adjustCellWidth: String
    var adjustCellHeight: String

    init(loadedFrom config: Ghostty.Config?) {
        self.family = config?.fontFamily ?? ""
        self.size = config?.fontSize ?? 13.0
        self.feature = config?.fontFeature ?? ""
        self.thicken = config?.fontThicken ?? false
        self.adjustCellWidth = config?.adjustCellWidth ?? ""
        self.adjustCellHeight = config?.adjustCellHeight ?? ""
    }
}

/// Editable Cursor state.
struct CursorForm: Equatable {
    var style: CursorStyleOption
    var blink: CursorBlinkOption
    var useTextColor: Bool
    var textColor: Color
    var opacity: Double
    var clickToMove: Bool

    init(loadedFrom config: Ghostty.Config?) {
        self.style = CursorStyleOption(rawValue: config?.cursorStyle ?? "block") ?? .block

        let blinkSetting = config?.cursorStyleBlink
        switch blinkSetting {
        case nil:    self.blink = .systemDefault
        case true:   self.blink = .on
        case false:  self.blink = .off
        }

        let txt = config?.cursorText
        self.useTextColor = txt != nil
        self.textColor = txt ?? .black

        self.opacity = config?.cursorOpacity ?? 1.0
        self.clickToMove = config?.cursorClickToMove ?? true
    }
}

/// Maps to Ghostty `cursor-style`.
enum CursorStyleOption: String, CaseIterable, Identifiable, Hashable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar (I-beam)"
        case .underline: return "Underline"
        case .blockHollow: return "Hollow Block"
        }
    }
}

/// Tri-state for `cursor-style-blink: ?bool`.
enum CursorBlinkOption: String, CaseIterable, Identifiable, Hashable {
    case systemDefault
    case on
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: return "System default"
        case .on: return "Always blink"
        case .off: return "Don't blink"
        }
    }
}

// MARK: - General form

struct GeneralForm: Equatable {
    var command: String
    var confirmClose: ConfirmCloseOption
    var quitAfterLastWindowClosed: Bool
    var scrollbackLimitMB: Double          // expose as megabytes for usability
    var mouseHideWhileTyping: Bool
    var focusFollowsMouse: Bool
    var copyOnSelect: CopyOnSelectOption
    var clipboardRead: ClipboardAccessOption
    var clipboardWrite: ClipboardAccessOption
    var workingDirectory: String
    var mouseScrollMultiplier: Double
    var clipboardPasteProtection: Bool
    var linkURL: Bool
    var showProgressBar: Bool

    init(loadedFrom config: Ghostty.Config?) {
        // `command` is a Zig union we can't read via the C API, so read it from
        // the config file (round-trips the common single-command case).
        self.command = config?.command ?? ""
        self.confirmClose = ConfirmCloseOption(rawValue: config?.confirmCloseSurface ?? "true") ?? .yes
        self.quitAfterLastWindowClosed = config?.quitAfterLastWindowClosed ?? false
        let bytes = config?.scrollbackLimit ?? 10_000_000
        self.scrollbackLimitMB = Double(bytes) / 1_000_000
        self.mouseHideWhileTyping = config?.mouseHideWhileTyping ?? false
        self.focusFollowsMouse = config?.focusFollowsMouse ?? false
        self.copyOnSelect = CopyOnSelectOption(rawValue: config?.copyOnSelect ?? "false") ?? .off
        self.clipboardRead = ClipboardAccessOption(rawValue: config?.clipboardRead ?? "ask") ?? .ask
        self.clipboardWrite = ClipboardAccessOption(rawValue: config?.clipboardWrite ?? "allow") ?? .allow
        self.workingDirectory = config?.workingDirectory ?? ""
        self.mouseScrollMultiplier = config?.mouseScrollMultiplier ?? 1.0
        self.clipboardPasteProtection = config?.clipboardPasteProtection ?? true
        self.linkURL = config?.linkURL ?? true
        self.showProgressBar = config?.progressStyle ?? true
    }
}

enum ConfirmCloseOption: String, CaseIterable, Identifiable, Hashable {
    case yes = "true", no = "false", always = "always"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .yes: return "If process is running"
        case .no: return "Never"
        case .always: return "Always"
        }
    }
}

enum CopyOnSelectOption: String, CaseIterable, Identifiable, Hashable {
    case off = "false", on = "true", clipboard = "clipboard"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "Selection buffer only"
        case .clipboard: return "System clipboard"
        }
    }
}

enum ClipboardAccessOption: String, CaseIterable, Identifiable, Hashable {
    case ask, allow, deny
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask each time"
        case .allow: return "Always allow"
        case .deny: return "Always deny"
        }
    }
}

// MARK: - Window form

struct WindowForm: Equatable {
    var decoration: WindowDecorationOption
    var saveState: WindowSaveStateOption
    var stepResize: Bool
    var paddingBalance: Bool
    var paddingX: String
    var paddingY: String

    init(loadedFrom config: Ghostty.Config?) {
        self.decoration = WindowDecorationOption(rawValue: config?.windowDecoration ?? "auto") ?? .auto
        self.saveState = WindowSaveStateOption(rawValue: config?.windowSaveState ?? "default") ?? .default
        self.stepResize = config?.windowStepResize ?? false
        self.paddingBalance = config?.windowPaddingBalance ?? false
        self.paddingX = config?.windowPaddingX ?? ""
        self.paddingY = config?.windowPaddingY ?? ""
    }
}

enum WindowDecorationOption: String, CaseIterable, Identifiable, Hashable {
    case auto, none, server, client
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (per-platform)"
        case .none: return "None"
        case .server: return "Server (OS)"
        case .client: return "Client (in-window)"
        }
    }
}

enum WindowSaveStateOption: String, CaseIterable, Identifiable, Hashable {
    case `default`, never, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "Default"
        case .never: return "Never"
        case .always: return "Always"
        }
    }
}

// MARK: - Tabs form

struct TabsForm: Equatable {
    var titlebarStyle: MacosTitlebarStyleOption
    var titlebarProxyIcon: MacosTitlebarProxyIconOption
    var newTabPosition: NewTabPositionOption

    init(loadedFrom config: Ghostty.Config?) {
        self.titlebarStyle = MacosTitlebarStyleOption(rawValue: config?.macosTitlebarStyleString ?? "transparent") ?? .transparent
        self.titlebarProxyIcon = MacosTitlebarProxyIconOption(rawValue: config?.macosTitlebarProxyIcon.rawValue ?? "visible") ?? .visible
        self.newTabPosition = NewTabPositionOption(rawValue: config?.windowNewTabPositionString ?? "current") ?? .current
    }
}

enum MacosTitlebarStyleOption: String, CaseIterable, Identifiable, Hashable {
    case native, transparent, tabs, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .native: return "Native"
        case .transparent: return "Transparent (blends with background)"
        case .tabs: return "Tabs in titlebar"
        case .hidden: return "Hidden"
        }
    }
}

enum MacosTitlebarProxyIconOption: String, CaseIterable, Identifiable, Hashable {
    case visible, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visible: return "Visible"
        case .hidden: return "Hidden"
        }
    }
}

enum NewTabPositionOption: String, CaseIterable, Identifiable, Hashable {
    case current, end
    var id: String { rawValue }
    var label: String {
        switch self {
        case .current: return "Right of current tab"
        case .end: return "End of tab bar"
        }
    }
}

// MARK: - Shell Integration form

struct ShellIntegrationForm: Equatable {
    var integration: ShellIntegrationOption
    var features: String       // raw comma-separated list

    init(loadedFrom config: Ghostty.Config?) {
        self.integration = ShellIntegrationOption(rawValue: config?.shellIntegration ?? "detect") ?? .detect
        // Load the raw `shell-integration-features` override list from the
        // config file. Unlisted features fall back to Ghostty's defaults (see
        // ShellIntegrationFeature.defaultOn) in the section view.
        self.features = config?.shellIntegrationFeatures ?? ""
    }
}

enum ShellIntegrationOption: String, CaseIterable, Identifiable, Hashable {
    case detect, none, bash, zsh, fish, elvish, nushell
    var id: String { rawValue }
    var label: String {
        switch self {
        case .detect: return "Auto-detect"
        case .none: return "Disabled"
        case .bash: return "Bash"
        case .zsh: return "Zsh"
        case .fish: return "Fish"
        case .elvish: return "Elvish"
        case .nushell: return "Nushell"
        }
    }
}

/// Catalog of known shell-integration feature toggles. Each can be turned
/// on or off; the config value is the space/comma-separated list of
/// enabled (or `no-`-prefixed disabled) features.
struct ShellIntegrationFeature {
    let tag: String
    let label: String
    let detail: String
    /// Ghostty's default when `shell-integration-features` doesn't mention it
    /// (see Config.zig `ShellIntegrationFeatures`). A toggle with no explicit
    /// override in the config reflects this.
    let defaultOn: Bool
}

extension ShellIntegrationFeature {
    /// Split a raw `shell-integration-features` override list (e.g.
    /// "ssh-env, no-cursor") into explicitly-enabled and explicitly-disabled
    /// tags. Unlisted features keep their `defaultOn`.
    static func parseOverrides(_ raw: String?) -> (on: Set<String>, off: Set<String>) {
        let parts = (raw ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let on = Set(parts.filter { !$0.hasPrefix("no-") })
        let off = Set(parts.filter { $0.hasPrefix("no-") }.map { String($0.dropFirst(3)) })
        return (on, off)
    }

    /// Effective on/off state for `tag` given the raw override list: an
    /// explicit override (or the `true`/`false` all-features form) wins,
    /// otherwise the feature's default applies.
    static func isEnabled(_ tag: String, overrides raw: String?) -> Bool {
        let (on, off) = parseOverrides(raw)
        if off.contains(tag) || on.contains("false") { return false }
        if on.contains(tag) || on.contains("true") { return true }
        return kShellIntegrationFeatures.first { $0.tag == tag }?.defaultOn ?? false
    }
}

let kShellIntegrationFeatures: [ShellIntegrationFeature] = [
    .init(tag: "cursor", label: "Cursor",
          detail: "Restore cursor to a bar at the prompt.", defaultOn: true),
    .init(tag: "sudo", label: "Sudo",
          detail: "Wrap sudo to preserve terminfo.", defaultOn: false),
    .init(tag: "title", label: "Title",
          detail: "Update window title via shell integration.", defaultOn: true),
    .init(tag: "ssh-env", label: "SSH env",
          detail: "Forward TERM and color env vars over SSH.", defaultOn: true),
    .init(tag: "ssh-terminfo", label: "SSH terminfo",
          detail: "Install Ghostty's terminfo on remote hosts.", defaultOn: true),
    .init(tag: "path", label: "PATH",
          detail: "Add Ghostty's binary directory to PATH.", defaultOn: true),
]

/// `background-image-fit` config knob.
enum BackgroundImageFit: String, CaseIterable, Identifiable, Hashable {
    case contain
    case cover
    case stretch
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contain: return "Contain (fit inside)"
        case .cover: return "Cover (fill, may crop)"
        case .stretch: return "Stretch"
        case .none: return "Original size"
        }
    }
}

/// `background-image-position` config knob.
enum BackgroundImagePosition: String, CaseIterable, Identifiable, Hashable {
    case topLeft = "top-left"
    case top
    case topRight = "top-right"
    case left
    case center
    case right
    case bottomLeft = "bottom-left"
    case bottom
    case bottomRight = "bottom-right"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// UI-friendly representation of the Ghostty `background-blur` config knob.
enum BackgroundBlurOption: String, CaseIterable, Identifiable, Hashable {
    case off
    case subtle
    case standard
    case strong
    case glassRegular
    case glassClear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .standard: return "Standard"
        case .strong: return "Strong"
        case .glassRegular: return "Liquid Glass (Regular)"
        case .glassClear: return "Liquid Glass (Clear)"
        }
    }

    /// Construct from the live Config blur model. Mapping is coarse — the
    /// underlying `radius(Int)` collapses into the bucketed options here.
    init(_ blur: Ghostty.Config.BackgroundBlur?) {
        guard let blur else {
            self = .off
            return
        }
        switch blur {
        case .disabled: self = .off
        case .radius(let r) where r <= 10: self = .subtle
        case .radius(let r) where r <= 25: self = .standard
        case .radius: self = .strong
        case .macosGlassRegular: self = .glassRegular
        case .macosGlassClear: self = .glassClear
        }
    }

    /// The string we'd emit into ~/.config/ghostty/config for this option.
    /// Used by B.3's save logic.
    var configValue: String {
        switch self {
        case .off: return "false"
        case .subtle: return "10"
        case .standard: return "20"
        case .strong: return "40"
        case .glassRegular: return "glass-regular"
        case .glassClear: return "glass-clear"
        }
    }
}

/// `window-theme` config knob.
enum WindowThemeOption: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark
    case auto
    case ghostty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Auto (by background color)"
        case .ghostty: return "Use Active Theme"
        }
    }
}

// MARK: - Sidebar

/// Left column: search field on top, sectioned list below.
///
/// We use a custom search field (not SwiftUI's `.searchable`) because that
/// modifier is tied to `NavigationSplitView`'s search slot. Since we're now
/// inside an `NSSplitViewController`-hosted view, we render the search field
/// ourselves so it sits cleanly under the titlebar.
struct SidebarView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if viewModel.isSearching {
                searchResultsList
            } else {
                sectionList
            }
        }
        .frame(minWidth: 200)
    }

    /// Normal mode: the list of sections.
    private var sectionList: some View {
        List(selection: $viewModel.selectedSection) {
            Section {
                ForEach(viewModel.filteredSections) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            } header: {
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .textCase(.uppercase)
            }
        }
        .listStyle(.sidebar)
    }

    /// Search mode: individual settings matching the query. Selecting one jumps
    /// to its section.
    private var searchResultsList: some View {
        List {
            let results = viewModel.searchResults
            if results.isEmpty {
                Text("No settings match “\(viewModel.searchText)”")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .padding(.vertical, 8)
            } else {
                Section {
                    ForEach(results) { entry in
                        Button {
                            viewModel.selectedSection = entry.section
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.section.icon)
                                    .foregroundStyle(.secondaryText)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .foregroundStyle(.primary)
                                    Text(entry.section.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if viewModel.selectedSection == entry.section {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                        .textCase(.uppercase)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondaryText)
            TextField("Search settings", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

// MARK: - Detail

/// Right column: section header (small) + section content.
///
/// In B.1+ each `SettingsSection` will dispatch to a dedicated form view.
struct DetailView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Group {
            if let section = viewModel.selectedSection {
                ScrollView {
                    // Centered, fixed-width content column. Same pattern as
                    // macOS System Settings: comfortable reading width that
                    // doesn't stretch with the window. Wide windows have
                    // equal empty space on both sides.
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 24) {
                            sectionHeader(section)
                            sectionContent(for: section)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: 720)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
            } else {
                placeholderEmptyView
            }
        }
        .frame(minWidth: 520)
    }

    private func sectionHeader(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSectionView(viewModel: viewModel)
        case .appearance:
            AppearanceSectionView(viewModel: viewModel)
        case .font:
            FontSectionView(viewModel: viewModel)
        case .cursor:
            CursorSectionView(viewModel: viewModel)
        case .window:
            WindowSectionView(viewModel: viewModel)
        case .tabs:
            TabsSectionView(viewModel: viewModel)
        case .shellIntegration:
            ShellIntegrationSectionView(viewModel: viewModel)
        case .keybinds:
            KeybindsSectionView(viewModel: viewModel)
        case .sftp:
            SFTPSectionView(viewModel: viewModel)
        case .sync:
            SyncSectionView()
        case .notifications:
            NotificationsSettingsView()
        case .advanced:
            AdvancedSectionView(viewModel: viewModel)
        }
    }

    private var placeholderEmptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 48))
                .foregroundStyle(.tertiaryText)
            Text("Select a settings section")
                .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Footer

/// Bottom bar. Every change applies live, so there's no "Save": instead the
/// footer confirms auto-saves (green flash) and offers per-section **Revert**
/// (undo changes made this visit) and **Reset to Default** (with a warning).
/// Lives outside the split view so its position is fixed regardless of the
/// sidebar state. Observes `SFTPSettings` too so the SFTP section's dirty
/// state keeps the Revert button in sync.
struct FooterBarView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var sftpSettings = SFTPSettings.shared
    @State private var showResetConfirm = false

    private var section: SettingsSection? { viewModel.selectedSection }

    var body: some View {
        HStack(spacing: 12) {
            statusMessage
            Spacer()
            if let section, viewModel.supportsFooterActions(section) {
                Button {
                    viewModel.revert(section: section)
                } label: {
                    Text("Revert").frame(minWidth: 60)
                }
                .controlSize(.large)
                .disabled(!viewModel.isDirty(section: section))
                .help("Undo the changes you made in this section")

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Text("Reset to Default").frame(minWidth: 60)
                }
                .controlSize(.large)
                .help("Restore every option in this section to its default value")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showSavedFlash)
        // Centered-logo SarvAlert — same dialog semantics everywhere.
        .onChange(of: showResetConfirm) { show in
            guard show else { return }
            SarvAlert.present(
                title: "Reset \(section?.title ?? "section") to defaults?",
                message: "This restores every option in this section to its default value. You can undo it with Revert until you close Settings.",
                buttons: [
                    .init("Reset to Default", isDefault: true, isDestructive: true),
                    .init("Cancel", isCancel: true),
                ]) { result in
                if result.buttonIndex == 0, let section { viewModel.resetToDefault(section: section) }
            }
            showResetConfirm = false
        }
    }

    /// Left side: the green "saved automatically" confirmation, or a write
    /// error if the last commit failed.
    @ViewBuilder
    private var statusMessage: some View {
        if let err = viewModel.lastSaveError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if viewModel.showSavedFlash {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .transition(.opacity)
        }
    }
}

// MARK: - Sections

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case font
    case window
    case tabs
    case cursor
    case keybinds
    case shellIntegration
    case sftp
    case sync
    case notifications
    case advanced

    /// Sections shown in the sidebar. `tabs` is hidden: its settings (titlebar
    /// style/proxy-icon, native new-tab position) don't apply to SarvTerminal's
    /// custom single-window UI.
    static var visibleSections: [SettingsSection] {
        allCases.filter { $0 != .tabs }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .font: return "Font"
        case .window: return "Window"
        case .tabs: return "Tabs"
        case .cursor: return "Cursor"
        case .keybinds: return "Keybinds"
        case .shellIntegration: return "Shell Integration"
        case .sftp: return "SFTP"
        case .sync: return "Sync"
        case .notifications: return "Notifications"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String? {
        switch self {
        case .general: return "Startup behaviour, default command, shell."
        case .appearance: return "Theme, colors, transparency, background."
        case .font: return "Family, size, weight, ligatures, variations."
        case .window: return "Decorations, size, padding, fullscreen."
        case .tabs: return "Tab bar style, position, behavior."
        case .cursor: return "Style, blinking, color, thickness."
        case .keybinds: return "Keyboard shortcuts and key tables."
        case .shellIntegration: return "Auto-cd, prompts, SSH features."
        case .sftp: return "File transfer: save behavior, deletes, hidden files."
        case .sync: return "Encrypted backup of your settings, keybinds, and hosts."
        case .notifications: return "Which events notify you, and the alert sound."
        case .advanced: return "Raw config editor and power-user options."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .font: return "textformat"
        case .window: return "macwindow"
        case .tabs: return "rectangle.stack"
        case .cursor: return "cursorarrow"
        case .keybinds: return "keyboard"
        case .shellIntegration: return "terminal"
        case .sftp: return "folder"
        case .sync: return "icloud"
        case .notifications: return "bell"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    /// Loose match against a search query. Matches title, subtitle, and a list
    /// of hand-curated keywords so users find sections by config-key adjacent
    /// terms (e.g. "opacity" → Appearance).
    func matchesSearch(_ query: String) -> Bool {
        if title.lowercased().contains(query) { return true }
        if let s = subtitle?.lowercased(), s.contains(query) { return true }
        return keywords.contains { $0.contains(query) }
    }

    private var keywords: [String] {
        switch self {
        case .general: return ["startup", "shell", "command", "init", "quit"]
        case .appearance: return ["theme", "color", "palette", "background", "foreground",
                                  "transparency", "opacity", "blur", "image"]
        case .font: return ["family", "size", "ligature", "feature", "bold", "italic",
                            "variation", "weight"]
        case .window: return ["decoration", "padding", "title", "fullscreen",
                              "save", "resize", "position", "level"]
        case .tabs: return ["tab", "titlebar", "split", "new tab"]
        case .cursor: return ["caret", "blink", "shape", "thickness", "bar", "underline", "block"]
        case .keybinds: return ["shortcut", "binding", "key", "hotkey", "table", "chord"]
        case .shellIntegration: return ["cursor", "prompt", "ssh", "sudo", "title", "path",
                                       "bash", "zsh", "fish", "elvish", "nushell"]
        case .sftp: return ["sftp", "scp", "file", "transfer", "save", "autosave",
                            "auto-save", "delete", "hidden", "editor"]
        case .sync: return ["sync", "cloud", "backup", "encrypt", "github", "folder",
                            "pull", "push", "master password", "icloud"]
        case .notifications: return ["notification", "alert", "sound", "bell", "notify",
                                     "banner", "claude", "prompt"]
        case .advanced: return ["config", "include", "raw", "editor", "power"]
        }
    }
}

// MARK: - Placeholder section content

private struct SectionPlaceholderView: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hammer")
                    .foregroundStyle(.orange)
                Text("Coming next iteration")
                    .font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )

            Text(stubBody)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stubBody: String {
        """
        Form controls for \(section.title.lowercased()) options will land in a follow-up \
        iteration. For now, edit `~/.config/ghostty/config` and press ⌘⇧, to reload.

        Run `ghostty +show-config --docs` in a terminal to see every available option \
        with documentation.
        """
    }
}

// MARK: - Legacy SwiftUI entry (kept for #Preview only)

/// Maintained so Xcode SwiftUI previews still work without an `NSWindow`.
/// The actual Settings window is now driven by `SettingsContainerViewController`.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                DetailView(viewModel: viewModel)
            }
            Divider()
            FooterBarView(viewModel: viewModel)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
