import AppKit
import Combine
import Network
import SwiftUI
import GhosttyKit
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    /// Drag payload content type for a Vaults terminal tab.
    static let vaultsTabID = UTType(exportedAs: "com.sarvterminal.vaultsTabID")
}

extension NSItemProvider {
    /// A drag payload carrying a tab id under the custom `vaultsTabID` type
    /// (NOT plain `public.text`). The terminal surface registers for `.string`,
    /// so a plain-text tab id would be swallowed by the terminal (and pasted!)
    /// instead of reaching the split drop zones. A custom type the terminal
    /// doesn't register for passes straight through to our drop targets.
    static func vaultsTab(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vaultsTabID.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Load a tab id previously registered via `vaultsTab(_:)`.
    func loadVaultsTabID(_ completion: @escaping (UUID?) -> Void) {
        _ = loadDataRepresentation(forTypeIdentifier: UTType.vaultsTabID.identifier) { data, _ in
            guard let data, let s = String(data: data, encoding: .utf8), let id = UUID(uuidString: s) else {
                completion(nil)
                return
            }
            completion(id)
        }
    }
}

extension Notification.Name {
    /// Posted when the "auto-adjust font weight for low-DPI screens" setting changes.
    static let sarvAutoFontWeightChanged = Notification.Name("com.sarv.terminal.autoFontWeightChanged")
    /// Posted by a surface (object = the `SurfaceView`) when its backing scale
    /// changes — i.e. on creation and when its window moves to another screen.
    static let sarvSurfaceBackingChanged = Notification.Name("com.sarv.terminal.surfaceBackingChanged")
    /// Posted (object = `SurfaceView`) when a surface emits an OSC desktop
    /// notification; `userInfo["title"]`/`["body"]` carry the message text.
    static let sarvSurfaceDesktopNotification = Notification.Name("com.sarv.terminal.surfaceDesktopNotification")
}

/// Transferable drag payload for a terminal tab (modern SwiftUI
/// `.draggable`/`.dropDestination` API). Used to reorder tab chips and to
/// inject a single-terminal tab into a split pane.
struct TabDragID: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vaultsTabID)
    }
}

/// Single-window tab model for the Vaults window.
///
/// The window shows EITHER the Vaults dashboard OR one embedded terminal tab
/// at a time. Each terminal tab owns a `SplitTree` of `Ghostty.SurfaceView`s
/// (one or more split panes) created directly — there are no separate terminal
/// windows and no native macOS window tabbing. See the `vaults-window-tabbing`
/// memory for the history.
///
/// Split handling (⌘D / ⌘⇧D etc.) is ported from `BaseTerminalController`:
/// libghostty posts notifications targeting the focused surface and we mutate
/// the owning tab's split tree.
final class VaultsTabsModel: ObservableObject {
    static let shared = VaultsTabsModel()

    /// A single terminal tab: a split tree of surfaces + its live title.
    final class TerminalTab: ObservableObject, Identifiable {
        let id = UUID()
        @Published var surfaceTree: SplitTree<Ghostty.SurfaceView>
        /// Auto-assigned base label ("Terminal", host label, …).
        @Published var title: String
        /// User-set name from "Rename Tab…", overrides `title` when present.
        @Published var customName: String?
        /// Optional accent color set via the "Tab Color" menu.
        @Published var color: Color?
        /// The command this tab launched with (e.g. an `ssh …` invocation), so
        /// "Duplicate Tab" can re-run it. nil for a plain local shell.
        var launchCommand: String?
        /// The saved session this tab was opened from or saved as — lets a
        /// linked session rename propagate to its open tab. In-memory only.
        var sessionID: UUID?
        /// When true, input typed in the focused pane is mirrored to every
        /// other pane in the tab.
        @Published var broadcasting: Bool = false
        /// Sidebar display-name overrides per pane. A duplicated pane gets the
        /// source pane's name here so it doesn't show a bare "~" before its
        /// shell sets a title.
        @Published var paneTitleOverrides: [UUID: String] = [:]
        /// The surface within this tab that currently has focus — used as the
        /// anchor when splitting from the palette.
        weak var focusedSurface: Ghostty.SurfaceView?

        /// The saved host this tab connected to, if any — carried so a
        /// reconnect or "Duplicate Tab" can re-run the guided connect (and
        /// prefill the password).
        var connectHost: SavedHost?

        /// The label shown on the chip (custom name wins).
        var displayName: String {
            if let customName, !customName.isEmpty { return customName }
            return title
        }

        init(surface: Ghostty.SurfaceView, name: String) {
            self.surfaceTree = .init(view: surface)
            self.title = name
        }

        /// Build a tab from a pre-assembled split tree — used when reopening a
        /// saved session, which recreates the whole layout up front.
        init(tree: SplitTree<Ghostty.SurfaceView>, name: String) {
            self.surfaceTree = tree
            self.title = name
        }
    }

    /// A staged SSH connection bound to a single surface (pane). Stored in
    /// `connections` keyed by the CURRENT surface's id — not the tab — so the
    /// popup follows the surface when it's dragged into another tab's split.
    /// `command` is carried here (not on the tab) because the owning tab can
    /// change as the surface moves between tabs.
    final class ActiveConnection {
        let model: SSHConnectionModel
        var controller: SSHConnectionController
        let command: String
        init(model: SSHConnectionModel, controller: SSHConnectionController, command: String) {
            self.model = model
            self.controller = controller
            self.command = command
        }
    }

    /// Preset tab colors (matches Ghostty's tab-color palette).
    struct TabColorOption: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    static let tabColorOptions: [TabColorOption] = [
        .init(id: "blue", name: "Blue", color: .blue),
        .init(id: "purple", name: "Purple", color: .purple),
        .init(id: "pink", name: "Pink", color: .pink),
        .init(id: "red", name: "Red", color: .red),
        .init(id: "orange", name: "Orange", color: .orange),
        .init(id: "yellow", name: "Yellow", color: .yellow),
        .init(id: "green", name: "Green", color: .green),
        .init(id: "teal", name: "Teal", color: .teal),
        .init(id: "gray", name: "Gray", color: .gray),
    ]

    /// What the window's content area currently shows.
    enum Selection: Equatable {
        case dashboard
        case terminal(UUID)
    }

    @Published private(set) var terminals: [TerminalTab] = [] {
        didSet {
            persistSession()
        }
    }
    /// Per-tab `objectWillChange` subscriptions so a change to a tab's OWN state
    /// (color, custom name, split layout, pane-title overrides) re-persists the
    /// session — not just adding/removing tabs. Rebuilt on every persist.
    private var tabObservers: [AnyCancellable] = []
    /// Per-surface `$title` subscriptions: pane titles live on the SURFACES,
    /// not the tab, so a manual rename (Change Terminal Title) or a shell
    /// retitle would otherwise never re-persist — and the terminate-time
    /// persist can't catch it when the app dies without a graceful quit.
    private var titleObservers: [AnyCancellable] = []
    /// Coalesce a burst of tab changes into a single write per runloop tick.
    private var persistScheduled = false
    /// Tabs from the previous run, loaded at init and offered for reopen once
    /// the app finishes launching. Cleared after the popup is answered.
    private var pendingRestore: [SavedSession] = []

    /// Tabs that rang the bell (e.g. a Claude Code prompt) while not on screen,
    /// so the tab chip can show an attention dot. Cleared when the tab is shown.
    @Published private(set) var attentionTabs: Set<UUID> = []
    /// Staged SSH connections, keyed by the current surface id of each. A pane
    /// shows the connection popup when its surface id has an entry here.
    @Published private(set) var connections: [UUID: ActiveConnection] = [:]
    @Published var selection: Selection = .dashboard {
        didSet {
            if case let .terminal(id) = selection {
                lastTerminalID = id
                attentionTabs.remove(id)
            }
        }
    }
    /// The most recently focused terminal — the target for "run snippet" when a
    /// dashboard (e.g. Snippets) is showing instead of a terminal.
    private var lastTerminalID: UUID?
    /// Surface IDs of freshly-split panes that are showing the inline chooser
    /// (blank pane) and waiting for the user to pick what to run.
    @Published private(set) var awaitingChoice: Set<UUID> = []
    /// Focus mode (⌘⇧M): show the active tab as a sidebar list of panes + one
    /// main pane, instead of the split grid. It's just an alternate view of the
    /// same split tree, so toggling back restores the grid.
    @Published var focusMode: Bool = false
    /// Which pane fills the main area in focus mode.
    @Published var focusModeSurfaceID: UUID?
    /// Show the "all tabs" overview grid.
    @Published var showAllTabs: Bool = false
    /// When set, the host editor is shown as a side panel over the current
    /// screen (driven by the SSH popup's "Edit host" — keeps the popup visible).
    @Published var editingHost: SavedHost?

    /// Drives the ad-hoc Serial Console connect sheet (device + baud picker).
    /// Set from the Hosts "Serial" button and the command palette; presented by
    /// `VaultsRootView`.
    @Published var presentingSerialConnect = false

    /// Recently closed tabs (oldest first), retained so they can be reopened
    /// with full state — local shell, SSH session, or a pending chooser — via
    /// the reopen-closed-tab shortcut (⌘⇧T). Retaining the `TerminalTab` keeps
    /// its live surface tree (and child processes) alive until the tab is
    /// reopened or evicted past `maxClosedTabs`.
    private var closedTabs: [(tab: TerminalTab, index: Int)] = []
    private let maxClosedTabs = 25

    private var observers: [NSObjectProtocol] = []
    /// Observers on the NSWorkspace center (sleep/wake) — removed in deinit.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Watches overall network reachability so a waiting connection can retry the
    /// instant connectivity returns (instead of sitting out the back-off timer).
    private let pathMonitor = NWPathMonitor()
    private var networkSatisfied = true

    private init() {
        // Capture the previous session BEFORE any tab mutation can overwrite
        // session.json (the `terminals` didSet persists on every change).
        pendingRestore = TabSessionStore.load()
        installObservers()
        installReachabilityAndWakeObservers()
    }

    // MARK: - Session restore

    /// Snapshot the open tabs as restorable entries. Each tab is captured as a
    /// full `SavedSession` so its split layout, per-pane working directories /
    /// SSH hosts, and pane titles all reopen exactly next launch.
    private func sessionSnapshot() -> [SavedSession] {
        terminals.compactMap { tab in
            guard var snapshot = makeSavedSession(from: tab, name: tab.displayName) else { return nil }
            // Carry the tab's saved-session link across relaunch, so ⌘S on a
            // restored tab still offers "update existing / save as new".
            snapshot.linkedSessionID = tab.sessionID
            return snapshot
        }
    }

    /// Persist the current open tabs so they can be reopened next launch.
    func persistSession() {
        // Splits and pane drags add surfaces without touching `terminals`, so
        // re-sync the tab and per-surface subscriptions on every persist.
        observeTabChanges()
        TabSessionStore.save(sessionSnapshot())
    }

    /// Subscribe to each open tab so changes to its own state (color, rename,
    /// split layout, pane titles) re-persist the session immediately.
    private func observeTabChanges() {
        tabObservers = terminals.map { tab in
            tab.objectWillChange.sink { [weak self] in self?.schedulePersist() }
        }
        titleObservers = terminals.flatMap { tab in
            (tab.surfaceTree.root?.leaves() ?? []).map { leaf in
                leaf.$title
                    .dropFirst()
                    .removeDuplicates()
                    .sink { [weak self] _ in self?.schedulePersist() }
            }
        }
    }

    /// Persist on the NEXT runloop (so the snapshot reads post-change values),
    /// at most once per tick even if several @Published fields changed at once.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.persistScheduled = false
            self?.persistSession()
        }
    }

    /// If the previous run left tabs open, ask whether to reopen them. Call
    /// once after the app finishes launching.
    func offerSessionRestoreIfNeeded() {
        let entries = pendingRestore
        pendingRestore = []
        guard !entries.isEmpty else { return }
        // Respect the "reopen tabs on launch" preference (default on). We keep
        // autosaving regardless, so re-enabling restores on a later launch.
        guard UserDefaults.standard.object(forKey: "SarvRestoreSession") as? Bool ?? true else { return }

        let n = entries.count
        // Called from app-launch on the main thread; not statically isolated.
        let result = MainActor.assumeIsolated {
            SarvAlert.runModal(
                title: "Reopen your last session?",
                message: "Reopen the \(n) tab\(n == 1 ? "" : "s") you had open when you last quit.",
                buttons: [
                    .init("Reopen All", isDefault: true),
                    .init("Not Now", isCancel: true),
                ])
        }
        if result.buttonIndex == 0 {
            restoreSession(entries)
        } else {
            // Declined → the current (empty) state replaces the saved session.
            persistSession()
        }
    }

    private func restoreSession(_ sessions: [SavedSession]) {
        // Each saved snapshot rebuilds one tab with its full split layout — local
        // panes respawn at their saved cwd, SSH panes reconnect, titles restore.
        for session in sessions { openSavedSession(session) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        pathMonitor.cancel()
    }

    // MARK: - Reachability & wake → instant reconnect

    /// Trigger an immediate reconnect (skipping the countdown) for every
    /// connection currently in the auto-reconnect loop. Used when the network
    /// comes back or the machine wakes from sleep — the events that most often
    /// follow a dropped SSH session.
    private func retryReconnectingNow(reason: String) {
        // Snapshot: retryNow() re-keys `connections` as it relaunches.
        for conn in Array(connections.values) where conn.model.autoReconnecting {
            conn.model.addLog("bolt.horizontal.circle", .secondary, reason)
            conn.controller.retryNow()
        }
    }

    private func installReachabilityAndWakeObservers() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let cameBack = satisfied && !self.networkSatisfied
                self.networkSatisfied = satisfied
                if cameBack { self.retryReconnectingNow(reason: "Network is back — reconnecting") }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        // Waking the machine (e.g. opening the lid) resumes the poll timers, which
        // detect the dropped session; nudge any waiting connection to retry now.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryReconnectingNow(reason: "Woke from sleep — reconnecting")
        }
        workspaceObservers.append(wake)
    }

    // MARK: - Queries

    var activeTerminal: TerminalTab? {
        guard case let .terminal(id) = selection else { return nil }
        return terminals.first { $0.id == id }
    }

    /// The surface a snippet should run in: the focused terminal, else the most
    /// recently focused one, else any open terminal.
    private var snippetTargetSurface: Ghostty.SurfaceView? {
        if case let .terminal(id) = selection, let s = surface(withID: id) { return s }
        if let id = lastTerminalID, let s = surface(withID: id) { return s }
        return terminals.last?.surfaceTree.root?.leaves().last
    }

    /// True when there's an open terminal a snippet can be sent to.
    var hasActiveTerminal: Bool { snippetTargetSurface != nil }

    /// Send a snippet's command to a terminal (adding a newline so it runs).
    /// Returns false when there's no terminal open to receive it.
    @MainActor @discardableResult
    func runSnippet(_ command: String) -> Bool {
        guard let surface = snippetTargetSurface else { return false }
        let text = command.hasSuffix("\n") ? command : command + "\n"
        surface.surfaceModel?.sendText(text)
        return true
    }

    /// Send a snippet to a SPECIFIC terminal tab and bring it to front. When
    /// `execute` is true a trailing newline runs it; otherwise it's just pasted.
    @MainActor @discardableResult
    func sendSnippet(_ command: String, toTabID id: UUID, execute: Bool) -> Bool {
        guard let tab = terminals.first(where: { $0.id == id }),
              let surface = tab.surfaceTree.root?.leaves().last,
              let model = surface.surfaceModel else { return false }
        // `sendText` is a bracketed paste — the shell won't auto-run a pasted
        // newline (a safety feature). So paste the text, then submit it with a
        // REAL Enter key event (which encodes properly and runs it).
        var text = command
        if execute { while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() } }
        model.sendText(text)
        if execute {
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        }
        selection = .terminal(id)   // show the terminal so the result is visible
        return true
    }

    /// The tab command-sidebar Run/Paste act on: the active tab, else the most
    /// recent, else any.
    private var commandTargetTab: TerminalTab? {
        if let t = activeTerminal { return t }
        if let id = lastTerminalID, let t = terminals.first(where: { $0.id == id }) { return t }
        return terminals.last
    }

    /// Panes a command targets: EVERY broadcast-eligible pane when the tab is
    /// broadcasting, otherwise just the focused pane (fallback: first leaf).
    private func commandTargetPanes(in tab: TerminalTab) -> [Ghostty.SurfaceView] {
        let leaves = tab.surfaceTree.root?.leaves() ?? []
        if tab.broadcasting {
            let eligible = leaves.filter { paneAcceptsBroadcast($0) }
            return eligible.isEmpty ? leaves : eligible
        }
        if let focused = tab.focusedSurface, leaves.contains(where: { $0 === focused }) {
            return [focused]
        }
        return leaves.first.map { [$0] } ?? []
    }

    /// Run a command in the FOCUSED pane of the active tab (or every pane when
    /// broadcasting). Pastes then submits with a REAL Enter — same mechanism as
    /// `sendSnippet`. Used by the command sidebar's Run button.
    @MainActor @discardableResult
    func runInTargetTerminal(_ command: String) -> Bool {
        guard let tab = commandTargetTab else { return false }
        var text = command
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        var sent = false
        for pane in commandTargetPanes(in: tab) {
            guard let model = pane.surfaceModel else { continue }
            model.sendText(text)
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
            sent = true
        }
        if sent { selection = .terminal(tab.id) }
        return sent
    }

    /// Paste text into the focused pane of the active tab (or every pane when
    /// broadcasting) WITHOUT running it. Used by the command sidebar's Paste button.
    @MainActor @discardableResult
    func pasteToTargetTerminal(_ command: String) -> Bool {
        guard let tab = commandTargetTab else { return false }
        var sent = false
        for pane in commandTargetPanes(in: tab) {
            guard let model = pane.surfaceModel else { continue }
            model.sendText(command)
            sent = true
        }
        if sent { selection = .terminal(tab.id) }
        return sent
    }

    /// The tab currently being drag-reordered / split (set by the AppKit chip
    /// drag source). Used to suppress split drop zones over that tab's OWN
    /// surfaces — you can't split a tab into itself. nil when no drag is active.
    var draggingTabID: UUID?

    /// True while a tab drag is in progress AND `surface` belongs to that same
    /// tab, so the split drop zones over it should be hidden.
    func isSelfTabDrag(over surface: Ghostty.SurfaceView) -> Bool {
        guard let draggingTabID, let tab = tab(containing: surface) else { return false }
        return tab.id == draggingTabID
    }

    private func tab(containing surface: Ghostty.SurfaceView) -> TerminalTab? {
        terminals.first { $0.surfaceTree.contains(surface) }
    }

    // MARK: - Connection registry (per surface)

    /// The surface id currently bound to `model`, if any.
    private func surfaceID(for model: SSHConnectionModel) -> UUID? {
        connections.first { $0.value.model === model }?.key
    }

    /// Find a live surface by id across every tab's split tree.
    private func surface(withID id: UUID) -> Ghostty.SurfaceView? {
        for tab in terminals {
            if let match = tab.surfaceTree.root?.leaves().first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Apply a saved host's per-host theme override to its terminal surface, so
    /// each host can carry its own look (empty `themeName` inherits the global
    /// theme). Deferred to the next runloop tick so the surface is initialized.
    private func applyHostTheme(_ host: SavedHost?, to surface: Ghostty.SurfaceView) {
        guard let host, !host.themeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let theme = host.themeName
        // Deferred to the next runloop tick so the surface is initialized.
        DispatchQueue.main.async { self.applyThemeSmart(theme, to: surface) }
    }

    /// Apply a theme to ONE surface, choosing the background the SAME way for
    /// host themes and the command-sidebar global theme. Decide on the fly
    /// whether the theme's TEXT is readable over the background image: keep the
    /// (translucent) image when it contrasts, otherwise pin the theme's own
    /// SOLID background so text is never washed out — and so a light theme's
    /// light background actually shows instead of only the text recoloring.
    /// The base config (loaded from the user's config file) carries the current
    /// font, so this applies font changes too.
    @MainActor
    func applyThemeSmart(_ theme: String, to surface: Ghostty.SurfaceView) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty,
              let s = surface.surface else { return }
        guard let colors = ghostty.themeColors(theme) else {
            ghostty.applyTheme(theme, to: s, backgroundHex: nil, opacity: ghostty.config.backgroundOpacity)
            return
        }
        let store = BackgroundDisplayStore.shared
        let windowBacking = 0.12
        if let imageLum = store.imageAverageLuminance {
            // A shared background image is showing: the pane renders TRANSLUCENT,
            // so text sits on a BLEND of the theme's background (pane opacity)
            // and the image behind it — judge readability against that blend,
            // never the raw image. Auto-adjust = find the LOWEST pane opacity
            // that keeps the theme's own text readable (image as visible as
            // possible, theme colors intact); flip the default text color only
            // if even a nearly-opaque pane can't get there.
            let minOpacity = BackgroundDisplayStore.sharedPaneOpacity
            let imageBackdrop = imageLum * store.imageVisibility + windowBacking * (1 - store.imageVisibility)
            func blend(_ opacity: Double) -> Double {
                colors.bgLum * opacity + imageBackdrop * (1 - opacity)
            }
            if abs(colors.fgLum - blend(minOpacity)) >= 0.4 {
                ghostty.applyTheme(theme, to: s, backgroundHex: nil, opacity: minOpacity)
            } else {
                // Solve blend(o) for the opacity where contrast reaches 0.4.
                let target = colors.bgLum > colors.fgLum ? colors.fgLum + 0.4 : colors.fgLum - 0.4
                let denominator = colors.bgLum - imageBackdrop
                let needed = denominator == 0 ? 1.0 : (target - imageBackdrop) / denominator
                if needed > 0, needed <= 0.92 {
                    ghostty.applyTheme(theme, to: s, backgroundHex: nil,
                                       opacity: max(minOpacity, needed))
                } else {
                    let contrastFg = blend(minOpacity) < 0.5 ? "#FFFFFF" : "#1E1E1E"
                    ghostty.applyTheme(theme, to: s, backgroundHex: nil, foregroundHex: contrastFg,
                                       opacity: minOpacity)
                }
            }
        } else if abs(colors.fgLum - windowBacking) >= 0.4 {
            // No image, theme text contrasts with the window backing — keep the
            // user's own translucency.
            ghostty.applyTheme(theme, to: s, backgroundHex: nil, opacity: ghostty.config.backgroundOpacity)
        } else {
            // No image — pin the theme's own solid background so the theme shows
            // instead of only the text recoloring.
            let solidHex = abs(colors.fgLum - colors.bgLum) >= 0.4
                ? colors.bgHex
                : (colors.fgLum < 0.5 ? "#FFFFFF" : "#1E1E1E")
            ghostty.applyTheme(theme, to: s, backgroundHex: solidHex, opacity: 1)
        }
    }

    /// Stop and forget the connection bound to `surfaceID` (if any), cleaning up
    /// its poll timer and password temp file.
    private func teardownConnection(surfaceID: UUID) {
        guard let conn = connections[surfaceID] else { return }
        conn.controller.stop()
        deleteTempFile(conn.model.passwordFilePath)
        connections[surfaceID] = nil
    }

    // MARK: - Tab mutations

    /// UserDefaults key backing the "New tab directory" preference. Empty → home.
    static let newTabDirectoryDefaultsKey = "SarvNewTabDirectory"

    /// Resolved working directory for a new blank terminal tab (⌘L). Defaults to
    /// the user's home directory; overridable via Settings ▸ General ▸ Startup ▸
    /// "New tab directory". A leading `~` is expanded.
    static var newTabWorkingDirectory: String {
        let raw = (UserDefaults.standard.string(forKey: newTabDirectoryDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return NSHomeDirectory() }
        return (raw as NSString).expandingTildeInPath
    }

    /// Create a new embedded terminal tab, select it, and bring the Vaults
    /// window forward. `name` is the base tab label ("Terminal" for a local
    /// shell, the host label for SSH) — deduped with "(1)", "(2)", … suffixes.
    /// Optionally inject a command once the shell is ready.
    @discardableResult
    func newTerminal(
        command: String? = nil,
        name: String = "Terminal",
        host: SavedHost? = nil,
        staged: Bool = false,
        workingDirectory: String? = nil
    ) -> TerminalTab? {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return nil }

        // Staged SSH connect: run ssh directly with the password fed via askpass
        // (no TTY prompt, no shell echo), driven by the connection popup.
        if staged, let command, command.hasPrefix("ssh ") {
            return startSSHConnection(app: app, command: command, name: name, host: host)
        }

        // Plain local terminal / non-staged command typed into a shell. When a
        // working directory is given (e.g. Duplicate Tab) we spawn the shell IN
        // it rather than typing `cd` afterwards — a typed `cd` races the shell's
        // login startup (profile scripts, dotenv prompts) and gets lost.
        let surface: Ghostty.SurfaceView = {
            if let workingDirectory, !workingDirectory.isEmpty {
                var cfg = Ghostty.SurfaceConfiguration()
                cfg.workingDirectory = workingDirectory
                return Ghostty.SurfaceView(app, baseConfig: cfg)
            }
            return Ghostty.SurfaceView(app)
        }()
        let tab = TerminalTab(surface: surface, name: uniqueTabName(base: name))
        tab.launchCommand = command
        tab.connectHost = host
        terminals.append(tab)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()
        Ghostty.moveFocus(to: surface)
        if let command {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                surface.surfaceModel?.sendText("\(command)\n")
            }
        }
        return tab
    }

    /// Open a serial console tab: spawn a surface running `screen <device> <baud>`
    /// directly (no shell prompt first). macOS ships `screen`, so there's nothing
    /// to install. Framing is `screen`'s default 8-N-1, no flow control.
    @discardableResult
    func newSerial(device: String, baud: Int) -> TerminalTab? {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return nil }
        var cfg = Ghostty.SurfaceConfiguration()
        // Single-quote the device path for the shell that runs the command.
        cfg.command = "screen '\(device)' \(baud)"
        let surface = Ghostty.SurfaceView(app, baseConfig: cfg)
        let tab = TerminalTab(surface: surface, name: uniqueTabName(base: "Serial \(SerialPorts.label(device))"))
        tab.launchCommand = cfg.command
        terminals.append(tab)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()
        Ghostty.moveFocus(to: surface)
        return tab
    }

    // MARK: - Staged SSH connection

    /// Whether the connection popup should collect a password in a field. Only
    /// "Ask" does — it has no stored password and prompts on every connect.
    /// "Password" hosts always carry a (mandatory) saved password, so they
    /// connect silently and, on failure, show the error card to fix via Edit
    /// host — they never show an inline prompt. Key/agent auth needs no password.
    private func sshNeedsPassword(_ host: SavedHost?) -> Bool {
        host?.authMethod == .ask
    }

    /// A surface that runs `command` (ssh) directly. The password is fed via the
    /// askpass helper, with the env baked into the command string (the command
    /// runs through `/bin/sh -c`, so this reliably reaches ssh regardless of the
    /// surface env plumbing). ssh's verbose stderr is redirected to `logFile` so
    /// the terminal shows only the clean remote session. Returns the surface and
    /// the temp password-file path (if any) so the caller can clean it up.
    /// Route a directly-spawned `ssh …` command through the app's `+ssh` CLI
    /// action so Host manager connections get the remote terminfo install /
    /// TERM fallback, same as the shell-integration ssh wrapper (which an
    /// app-spawned ssh bypasses — no interactive shell means no wrapper).
    /// Honors `shell-integration-features` overrides from the config file.
    private func wrapWithPlusSSH(_ command: String) -> String {
        guard command.hasPrefix("ssh "),
              let exe = Bundle.main.executablePath else { return command }
        let overrides = Ghostty.Config.rawConfigFileValue("shell-integration-features")
        let forwardEnv = ShellIntegrationFeature.isEnabled("ssh-env", overrides: overrides)
        let terminfo = ShellIntegrationFeature.isEnabled("ssh-terminfo", overrides: overrides)
        guard forwardEnv || terminfo else { return command }
        var flags: [String] = []
        if !forwardEnv { flags.append("--forward-env=false") }
        if !terminfo { flags.append("--terminfo=false") }
        let flagsPart = flags.isEmpty ? "" : "\(flags.joined(separator: " ")) "
        return "\(shellQuote(exe)) +ssh \(flagsPart)-- \(command.dropFirst(4))"
    }

    private func makeSSHSurface(app: ghostty_app_t, command: String, password: String?)
        -> (surface: Ghostty.SurfaceView, passwordFile: String?) {
        var full = wrapWithPlusSSH(command)
        var passwordFile: String?
        if let pw = password, !pw.isEmpty {
            let env = SSHAskpass.env(forPassword: pw)
            passwordFile = env["SARV_ASKPASS_FILE"]
            // Use the `env` command (not bare VAR=val) so the assignments
            // survive macOS's `bash -c "exec -l <command>"` wrapper, where
            // `exec -l VAR=val ssh` would treat "VAR=val" as the program name.
            let prefix = env.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
            if !prefix.isEmpty { full = "env \(prefix) \(full)" }
        }
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.command = full
        return (Ghostty.SurfaceView(app, baseConfig: cfg), passwordFile)
    }

    /// Remove the askpass password temp file (no-op if nil/absent) so we never
    /// leave orphans. The connection log is kept entirely in memory.
    private func deleteTempFile(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func startSSHConnection(app: ghostty_app_t, command: String, name: String, host: SavedHost?) -> TerminalTab? {
        let needsPassword = sshNeedsPassword(host)
        // Always start over a blank placeholder surface; ssh is spawned only
        // after the pre-flight host-key check (and password step) resolve.
        let surface = Ghostty.SurfaceView(app)
        let tab = TerminalTab(surface: surface, name: uniqueTabName(base: host?.label ?? name))
        tab.launchCommand = command
        tab.connectHost = host
        terminals.append(tab)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()

        let model = SSHConnectionModel(title: host?.label ?? name, host: host, needsPassword: needsPassword)
        let controller = SSHConnectionController(model: model, surfaceView: surface, tabsModel: self)
        connections[surface.id] = ActiveConnection(model: model, controller: controller, command: command)

        Task { @MainActor in await runHostKeyPreflight(model: model) }
        return tab
    }

    /// Before spawning ssh, verify the host key out-of-band. If it's unknown we
    /// scan it and show the trust card; otherwise we proceed straight to connect.
    @MainActor
    private func runHostKeyPreflight(model: SSHConnectionModel) async {
        if let host = model.host {
            let token = HostKeyScanner.token(host: host.hostname, port: host.port)
            if await HostKeyScanner.isKnown(token) == false {
                model.addLog("magnifyingglass", .secondary, "Checking host key…")
                if let scan = await HostKeyScanner.scan(host: host.hostname, port: host.port) {
                    model.scannedHostKeyLines = scan.lines
                    model.hostKeyToken = token
                    model.showLogs = false
                    model.stage = .needsHostKey(HostKeyInfo(
                        host: token, keyType: scan.keyType, fingerprint: scan.fingerprint, changed: false))
                    return   // wait for the user's choice (controller.acceptHostKey)
                }
                // Scan failed (host unreachable) — let the real connect surface the error.
            }
        }
        proceedConnect(model: model)
    }

    /// Continue past the host-key step: collect a password if needed, else spawn ssh.
    @MainActor
    func proceedConnect(model: SSHConnectionModel) {
        if model.requiresPassword {
            model.stage = .needsPassword     // popup collects it; submit → launchSSHConnection
        } else {
            launchSSHConnection(for: model, password: model.host?.password ?? "")
        }
    }

    /// (Re)launch ssh for `model` with `password` — spawns a fresh ssh surface
    /// with the askpass env, replaces JUST this connection's pane in its tab's
    /// split tree (so splits survive), restarts the controller, and re-keys the
    /// connection to the new surface. Backs password submit and Reconnect.
    func launchSSHConnection(for model: SSHConnectionModel, password: String) {
        guard let oldID = surfaceID(for: model),
              let conn = connections[oldID],
              let oldSurface = surface(withID: oldID),
              let tab = tab(containing: oldSurface),
              let node = tab.surfaceTree.root?.node(view: oldSurface),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        deleteTempFile(model.passwordFilePath)   // discard the previous attempt's password file
        // Rebuild the command from the LATEST saved host (the user may have just
        // edited it), so changed port/options take effect on reconnect.
        let command = model.host
            .flatMap { SavedHostsStore.shared.host(withID: $0.id) }
            .map { $0.sshCommand(staged: true) } ?? conn.command
        let made = makeSSHSurface(app: app, command: command, password: password)
        applyHostTheme(model.host, to: made.surface)
        // Replace only this pane's node — works whether it's the whole tab or one
        // pane of a split.
        if let newTree = try? tab.surfaceTree.replacing(node: node, with: .leaf(view: made.surface)) {
            tab.surfaceTree = newTree
        } else {
            tab.surfaceTree = .init(view: made.surface)
        }
        model.passwordFilePath = made.passwordFile
        model.silent = true            // attempting with a known password — no field while connecting
        model.stage = .connecting
        conn.controller.stop()
        let controller = SSHConnectionController(model: model, surfaceView: made.surface, tabsModel: self)
        // Re-key the connection to the new surface (with the refreshed command).
        connections[oldID] = nil
        connections[made.surface.id] = ActiveConnection(model: model, controller: controller, command: command)
        controller.start()
    }

    /// Open the host editor for this connection's host (popup "Edit host") as a
    /// side panel over the current screen, so the connection popup stays visible.
    /// On save the popup's Connect / Start over re-reads the updated host.
    func editHost(for model: SSHConnectionModel) {
        guard let host = model.host else { return }
        editingHost = SavedHostsStore.shared.host(withID: host.id) ?? host
    }

    /// Reconnect / "Start over" (popup button): reset the attempt count. After an
    /// auth failure on a password host, re-prompt for the password (don't retry
    /// the known-wrong one); otherwise relaunch the connection.
    /// Number of connection popups currently in a reconnectable state
    /// (failed or disconnected) — drives the "Reconnect all" button.
    var reconnectablePopupCount: Int {
        connections.values.reduce(into: 0) { count, conn in
            switch conn.model.stage {
            case .failed, .disconnected: count += 1
            default: break
            }
        }
    }

    /// Reconnect every popup that's in a failed/disconnected state at once —
    /// one click recovers all dropped sessions (e.g. after the network blips
    /// while several split panes are connected). Auto-reconnecting popups skip
    /// their countdown; the rest start over.
    func reconnectAllPopups() {
        for conn in Array(connections.values) {
            switch conn.model.stage {
            case .failed, .disconnected:
                if conn.model.autoReconnecting {
                    conn.controller.retryNow()
                } else {
                    reconnect(for: conn.model)
                }
            default:
                break
            }
        }
    }

    func reconnect(for model: SSHConnectionModel) {
        model.passwordAttempts = 0
        model.autoReconnecting = false
        model.reconnectAttempts = 0
        model.reconnectSecondsRemaining = 0
        // Pick up a password the user may have just corrected via "Edit host" —
        // this is what makes Start over work after fixing a wrong saved password.
        if let host = model.host, let latest = SavedHostsStore.shared.host(withID: host.id) {
            model.passwordField = latest.password
        }
        // Only "Ask" hosts re-prompt for a password; "Password" hosts relaunch
        // with the (corrected) saved password — no inline prompt.
        if case .failed(.permissionDenied) = model.stage, model.host?.authMethod == .ask {
            model.logEntries = []
            model.silent = false
            model.stage = .needsPassword
        } else {
            launchSSHConnection(for: model, password: model.passwordField)
        }
    }

    /// The session authenticated: hide the popup (show the live terminal) and
    /// save the working password to the host so future connects are silent.
    func connectionDidConnect(for model: SSHConnectionModel) {
        // Persist a working password only for "Password" hosts. "Ask" hosts must
        // prompt every connect, so we never store what was typed for them.
        if let host = model.host, host.authMethod != .ask,
           !model.passwordField.isEmpty, host.password != model.passwordField {
            var updated = host
            updated.password = model.passwordField
            SavedHostsStore.shared.upsert(updated)
        }
        model.stage = .connected
        // Logged in: drop the askpass password file. ssh keeps its now-unlinked
        // fd; the file is freed when ssh exits.
        deleteTempFile(model.passwordFilePath)
        model.passwordFilePath = nil
        if let id = surfaceID(for: model), let surface = surface(withID: id) {
            Ghostty.moveFocus(to: surface)
            // Startup command (host editor → Startup): typed into the freshly
            // opened remote shell exactly as entered — one command per line,
            // and `&&` chains work like in any shell.
            if let host = model.host {
                let startup = host.initialCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                if !startup.isEmpty { send(startup, to: surface) }
            }
        }
    }

    /// A tab label unique among open tabs: `base`, else `base (1)`, `base (2)`…
    ///
    /// Any trailing " (N)" numbering on `base` is stripped first so that
    /// duplicating an already-numbered tab increments the counter
    /// ("Terminal (1)" → "Terminal (2)") instead of nesting another suffix
    /// ("Terminal (1) (1)"). Duplicate Tab passes the source's full
    /// displayName as the base, so the stripping has to happen here.
    private func uniqueTabName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let stem = trimmed
            .replacingOccurrences(of: #"(\s*\(\d+\))+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let name = stem.isEmpty ? "Terminal" : stem
        let existing = Set(terminals.map { $0.displayName })
        if !existing.contains(name) { return name }
        var n = 1
        while existing.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// Split the active terminal tab in `direction` and present the inline
    /// chooser ("blank pane") on the new pane. The new surface spawns a local
    /// shell immediately (hidden behind the chooser); resolving the choice
    /// either reveals it (Local Terminal) or runs an SSH command in it.
    func splitAwaitingChoice(direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let tab = activeTerminal,
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        let anchor = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        guard let anchor else { return }
        let newView = Ghostty.SurfaceView(app)
        guard let newTree = try? tab.surfaceTree.inserting(view: newView, at: anchor, direction: direction) else { return }
        tab.surfaceTree = newTree
        // Don't steal focus to the surface — the chooser overlay wants it.
        awaitingChoice.insert(newView.id)
    }

    /// Resolve a pending split pane's chooser selection.
    func resolveChoice(surface: Ghostty.SurfaceView, action: PaletteAction) {
        switch action {
        case .serial:
            // Not supported in a split; leave the chooser up.
            return
        case .localTerminal:
            dismissChoice(surface: surface)
        case .host(let host):
            send(host.sshCommand, to: surface)
            dismissChoice(surface: surface)
        case .savedHost(let host):
            // Staged connect (popup + saved password) right in this pane.
            connectSavedHostInPane(host: host, surface: surface)
        case .quickConnect(let query):
            let target = query.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return }
            let command = target.hasPrefix("ssh ") ? target : "ssh \(target)"
            send(command, to: surface)
            dismissChoice(surface: surface)
        }
    }

    /// Start a staged SSH connection to `host` IN an existing (awaiting) split
    /// pane rather than a new tab — backs the split chooser's saved-host rows.
    /// The popup shows over this pane; on connect the live terminal replaces it
    /// in place, and the per-surface connection registry handles the rest.
    func connectSavedHostInPane(host: SavedHost, surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        let command = host.sshCommand(staged: true)
        let needsPassword = sshNeedsPassword(host)
        let knownPassword = host.password.isEmpty ? nil : host.password

        awaitingChoice.remove(surface.id)

        let boundSurface: Ghostty.SurfaceView
        var passwordFile: String?
        if needsPassword {
            // Keep the placeholder surface; the popup collects the password.
            boundSurface = surface
        } else {
            // Swap the placeholder pane for a live ssh surface.
            let made = makeSSHSurface(app: app, command: command, password: knownPassword)
            boundSurface = made.surface
            passwordFile = made.passwordFile
            applyHostTheme(host, to: made.surface)
            if let newTree = try? tab.surfaceTree.replacing(node: node, with: .leaf(view: made.surface)) {
                tab.surfaceTree = newTree
            }
        }

        let model = SSHConnectionModel(title: host.displayLabel, host: host, needsPassword: needsPassword)
        if !needsPassword { model.passwordFilePath = passwordFile }
        let controller = SSHConnectionController(model: model, surfaceView: boundSurface, tabsModel: self)
        connections[boundSurface.id] = ActiveConnection(model: model, controller: controller, command: command)
        // Label the pane with the host name: the live SSH surface title is the
        // generic ghost default, so without this the split header reads as a bare
        // ghost. Stored in paneTitleOverrides so it also survives save/restore.
        tab.paneTitleOverrides[boundSurface.id] = host.displayLabel
        if needsPassword {
            // Let the popup's password field take focus (don't pull it to the pane).
        } else {
            controller.start()
            Ghostty.moveFocus(to: boundSurface)
        }
    }

    /// Reveal the already-running local shell behind the chooser (Local
    /// Terminal choice).
    func dismissChoice(surface: Ghostty.SurfaceView) {
        awaitingChoice.remove(surface.id)
        Ghostty.moveFocus(to: surface)
    }

    /// Replace an awaiting (chooser) pane with a single-terminal tab dragged
    /// from the strip — the empty split becomes that tab, and it's removed from
    /// the strip.
    /// The sticky pane-title override for a surface, if one was recorded — a tab
    /// dragged into a split (or a split-off pane) keeps a meaningful name even
    /// though the surface's own live title is generic/ghost. nil → live title.
    func paneTitleOverride(for surfaceID: UUID) -> String? {
        for tab in terminals {
            if let name = tab.paneTitleOverrides[surfaceID], !name.isEmpty {
                // A manual rename (Change Terminal Title) beats the stored
                // override — otherwise the override masks it forever. Renaming
                // back to blank restores the override.
                for surface in tab.surfaceTree where surface.id == surfaceID {
                    if surface.isUserTitled { return nil }
                }
                return name
            }
        }
        return nil
    }

    func injectTabIntoAwaiting(awaiting: Ghostty.SurfaceView, draggedTabID: UUID) {
        guard let destTab = tab(containing: awaiting),
              let awaitingNode = destTab.surfaceTree.root?.node(view: awaiting),
              let srcIdx = terminals.firstIndex(where: { $0.id == draggedTabID }),
              terminals[srcIdx].id != destTab.id else { return }
        let srcTab = terminals[srcIdx]
        let leaves = srcTab.surfaceTree.root?.leaves() ?? []
        guard leaves.count == 1, let draggedSurface = leaves.first else { return }
        guard let newTree = try? destTab.surfaceTree.replacing(
            node: awaitingNode, with: .leaf(view: draggedSurface)) else { return }
        awaitingChoice.remove(awaiting.id)
        // Preserve the dragged tab's name as the new pane's header title. The
        // moved surface keeps its own live title (for an SSH tab that's the
        // ghost default), so without this the pane header would drop the tab's
        // name (e.g. "Local SSH 3333") and show a bare ghost.
        destTab.paneTitleOverrides[draggedSurface.id] = srcTab.displayName
        // The surface moves into the split. Its SSH connection (popup) follows
        // automatically — it's keyed by surface id, not by tab — so an in-flight
        // password prompt / connecting state keeps showing over the new pane.
        terminals.remove(at: srcIdx)
        destTab.surfaceTree = newTree
        Ghostty.moveFocus(to: draggedSurface)
    }

    /// Close a single split pane (from its header's × button). Collapses the
    /// split, or closes the tab if it was the last pane.
    func closePane(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        awaitingChoice.remove(surface.id)
        teardownConnection(surfaceID: surface.id)   // drop this pane's SSH popup, if any
        let remaining = tab.surfaceTree.removing(node)
        if remaining.isEmpty {
            closeTerminal(tab.id)
        } else {
            tab.surfaceTree = remaining
            if let next = remaining.root?.leftmostLeaf() {
                Ghostty.moveFocus(to: next)
            }
        }
    }

    /// Duplicate a single pane (focus-mode sidebar → Duplicate). Splits off a
    /// new pane next to it. If the source is still an unresolved "blank" pane,
    /// the duplicate is also blank (shows the chooser); otherwise it re-runs the
    /// tab's launch command (SSH) or `cd`s a local shell to the source's cwd.
    func duplicatePane(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        // Split along the pane's longer axis so the new pane gets usable space.
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection =
            surface.bounds.width >= surface.bounds.height ? .right : .down
        // Prefer the source pane's own SSH command (it travels with the surface,
        // so a migrated SSH pane still duplicates correctly); fall back to the
        // tab's launch command. A plain local shell instead duplicates at the
        // source cwd, set on the surface so it spawns there.
        let command = connections[surface.id]?.command ?? tab.launchCommand
        let newView: Ghostty.SurfaceView = {
            if command == nil, let cwd = surface.pwd, !cwd.isEmpty {
                var cfg = Ghostty.SurfaceConfiguration()
                cfg.workingDirectory = cwd
                return Ghostty.SurfaceView(app, baseConfig: cfg)
            }
            return Ghostty.SurfaceView(app)
        }()
        let sourceAwaiting = awaitingChoice.contains(surface.id)
        if !sourceAwaiting {
            // Show the source pane's name in the sidebar immediately (the new
            // shell's own title arrives later and can read as a bare "~").
            let sourceName = tab.paneTitleOverrides[surface.id]
                ?? (surface.title.isEmpty ? "Terminal" : surface.title)
            tab.paneTitleOverrides[newView.id] = sourceName
        }
        guard let newTree = try? tab.surfaceTree.inserting(
            view: newView, at: surface, direction: direction) else { return }
        tab.surfaceTree = newTree
        if sourceAwaiting {
            // Mirror the blank/selection state — don't steal focus or run a
            // shell command; the chooser overlay handles it.
            awaitingChoice.insert(newView.id)
            return
        }
        Ghostty.moveFocus(to: newView)
        // An SSH/launch command travels with the surface; re-run it. A plain
        // local shell already spawned in the source cwd (set above).
        if let command {
            send(command, to: newView)
        }
    }

    /// Toggle "focus mode" (zoom) on a pane — the pane fills the tab; toggle
    /// again to restore the split layout.
    func toggleZoom(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        if tab.surfaceTree.zoomed != nil {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: nil)
        } else {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: node)
        }
    }

    // MARK: - Tab drag & drop

    /// Reorder: move the dragged tab onto `targetID`'s slot — works in both
    /// directions (dragging right inserts after the target, dragging left
    /// inserts before it, so the dropped tab lands where you dropped it).
    /// Animated so chips slide into place instead of snapping.
    /// Detach a pane from its multi-pane tab into a standalone tab — the
    /// reverse of dragging a tab into a split. `before` = the tab chip it was
    /// dropped on (nil = append at the end). Detaching the only pane of a tab
    /// degenerates to a plain tab reorder. The live surface moves as-is, so a
    /// running process / SSH session survives (connections are keyed by
    /// surface id, not tab).
    func detachPane(surfaceID: UUID, before targetTabID: UUID?) {
        guard let tab = terminals.first(where: { t in
            t.surfaceTree.root?.leaves().contains(where: { $0.id == surfaceID }) ?? false
        }), let surface = tab.surfaceTree.root?.leaves().first(where: { $0.id == surfaceID })
        else { return }

        // Only pane in its tab → nothing to detach, just reorder the tab.
        if (tab.surfaceTree.root?.leaves().count ?? 0) <= 1 {
            if let targetTabID, targetTabID != tab.id { moveTab(tab.id, before: targetTabID) }
            return
        }

        guard let node = tab.surfaceTree.root?.node(view: surface) else { return }
        // Name the new tab from the pane's STICKY name (host label / carried
        // tab name) when it has one; otherwise the standard deduped "Terminal"
        // — never the live shell title, which flips between "~" and
        // "user@host:cwd" on every prompt and reads as broken.
        let name = uniqueTabName(base: tab.paneTitleOverrides[surfaceID] ?? "Terminal")
        tab.paneTitleOverrides[surfaceID] = nil
        tab.surfaceTree = tab.surfaceTree.removing(node)

        let newTab = TerminalTab(tree: .init(view: surface), name: name)
        withAnimation(.smooth(duration: 0.22)) {
            if let targetTabID, let idx = terminals.firstIndex(where: { $0.id == targetTabID }) {
                terminals.insert(newTab, at: idx)
            } else {
                terminals.append(newTab)
            }
        }
        selection = .terminal(newTab.id)
        DispatchQueue.main.async { Ghostty.moveFocus(to: surface) }
    }

    func moveTab(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = terminals.firstIndex(where: { $0.id == draggedID }),
              let originalTo = terminals.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            let tab = terminals.remove(at: from)
            guard let newTo = terminals.firstIndex(where: { $0.id == targetID }) else {
                terminals.append(tab)
                return
            }
            // Dragging rightward (from before the target) → land after it;
            // dragging leftward → land before it.
            let insertIndex = from < originalTo ? newTo + 1 : newTo
            terminals.insert(tab, at: insertIndex)
        }
    }

    /// Inject a single-terminal tab into another tab's split, at
    /// `destinationSurface` in the drop `zone`'s direction. Multi-pane source
    /// tabs are rejected (a tab that already has a split can't be dragged in).
    func injectTab(_ sourceTabID: UUID, into destinationSurface: Ghostty.SurfaceView, zone: TerminalSplitDropZone) {
        guard let sourceIdx = terminals.firstIndex(where: { $0.id == sourceTabID }) else { return }
        let sourceTab = terminals[sourceIdx]
        let leaves = sourceTab.surfaceTree.root?.leaves() ?? []
        guard leaves.count == 1, let surface = leaves.first else { return }
        guard let destTab = tab(containing: destinationSurface), destTab.id != sourceTabID else { return }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        guard let newTree = try? destTab.surfaceTree.inserting(view: surface, at: destinationSurface, direction: direction) else { return }
        // Remove the source tab WITHOUT freeing the surface — it now lives in the
        // destination tab's tree. Its SSH connection (popup) follows the surface
        // automatically (keyed by surface id), so an in-flight password prompt or
        // connecting/failed state keeps showing over the new pane in the split.
        terminals.remove(at: sourceIdx)
        destTab.surfaceTree = newTree
        selection = .terminal(destTab.id)
        Ghostty.moveFocus(to: surface)
    }

    /// Toggle input broadcasting for the pane's tab.
    func toggleBroadcast(surface: Ghostty.SurfaceView) {
        tab(containing: surface)?.broadcasting.toggle()
    }

    func isBroadcasting(surface: Ghostty.SurfaceView) -> Bool {
        tab(containing: surface)?.broadcasting ?? false
    }

    /// When the active tab is broadcasting, send `event` to every OTHER pane
    /// (not the one that natively handles it). The focused pane keeps its
    /// native key handling — including IME, backspace, and ⌘K — so we DON'T
    /// consume the event. The other panes get the key via the core
    /// (`ghostty_surface_key`), bypassing the NSView/IME pipeline that caused
    /// the doubled input. No-op (and irrelevant) when not broadcasting or the
    /// tab has a single pane.
    func broadcastKeyEvent(_ event: NSEvent) {
        guard let tab = activeTerminal, tab.broadcasting else { return }
        let panes = tab.surfaceTree.root?.leaves() ?? []
        guard panes.count > 1 else { return }

        // The pane that will handle this event natively (the first responder).
        let responder = event.window?.firstResponder as? NSView
        let source = panes.first { pane in
            guard let responder else { return false }
            return responder === pane || responder.isDescendant(of: pane)
        }

        for pane in panes where pane !== source && paneAcceptsBroadcast(pane) {
            guard let surface = pane.surface else { continue }
            sendKeyToCore(event, surface: surface)
        }
    }

    /// Whether a pane is a live, working terminal that should receive broadcast
    /// input. Panes still showing the SSH connection popup (needs-password /
    /// connecting / failed / disconnected) or the blank "open in this split"
    /// chooser have no usable shell behind them — sending keys there does nothing
    /// useful and can dismiss the pane, so they're excluded. A `connected` SSH
    /// pane (popup hidden) and plain local shells DO receive input.
    private func paneAcceptsBroadcast(_ pane: Ghostty.SurfaceView) -> Bool {
        if awaitingChoice.contains(pane.id) { return false }
        if let conn = connections[pane.id], conn.model.showsCard { return false }
        return true
    }

    /// Send a key event straight to a surface's core, mirroring the encode
    /// rules in `SurfaceView.keyAction`: pass `text` only for plain printable
    /// characters; let Ghostty encode control keys (backspace, ctrl-c, ctrl-l,
    /// arrows…) from the keycode + mods.
    private func sendKeyToCore(_ event: NSEvent, surface: ghostty_surface_t) {
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        var keyEvent = event.ghosttyKeyEvent(action)
        let text = event.characters ?? ""
        if let cp = text.utf8.first, cp >= 0x20, cp != 0x7f {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func send(_ command: String, to surface: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            surface.surfaceModel?.sendText("\(command)\n")
        }
    }

    /// Show the dashboard at the given section (Vaults / SFTP / SCP).
    func selectDashboard(section: HostManagerSelection.Section) {
        HostManagerSelection.shared.section = section
        selection = .dashboard
    }

    func selectTerminal(_ id: UUID) {
        selection = .terminal(id)
    }

    /// Select the Nth terminal tab (0-based) — backs ⌘1…⌘8.
    func selectTab(index: Int) {
        guard terminals.indices.contains(index) else { return }
        selection = .terminal(terminals[index].id)
    }

    // MARK: - Keybind-driven navigation (Ghostty defaults; wired in AppDelegate)
    //
    // These mirror Ghostty's macOS default keybinds. libghostty normally posts
    // these actions to a BaseTerminalController / native tab group — neither of
    // which the embedded Vaults window is — so the core handlers no-op and we
    // perform the equivalent here.

    /// `next_tab` / `previous_tab` — cycle the selection with wraparound.
    func cycleTab(_ delta: Int) {
        guard !terminals.isEmpty else { return }
        let current: Int = {
            if case let .terminal(id) = selection,
               let idx = terminals.firstIndex(where: { $0.id == id }) { return idx }
            return 0
        }()
        let n = terminals.count
        let next = ((current + delta) % n + n) % n
        selection = .terminal(terminals[next].id)
    }

    /// `last_tab` — select the final tab.
    func selectLastTab() {
        guard let last = terminals.last else { return }
        selection = .terminal(last.id)
    }

    /// `goto_split` — move keyboard focus to the adjacent split in the active tab.
    func focusSplit(_ direction: Ghostty.SplitFocusDirection) {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf(),
              let node = tab.surfaceTree.root?.node(view: current),
              let next = tab.surfaceTree.focusTarget(
                for: direction.toSplitTreeFocusDirection(), from: node)
        else { return }
        Ghostty.moveFocus(to: next, from: current)
    }

    /// `toggle_split_zoom` — on the active tab's focused pane.
    func toggleZoomActive() {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        else { return }
        toggleZoom(surface: current)
    }

    /// `close_surface` — close the active tab's focused pane (closes the tab if
    /// it was the last pane).
    func closeFocusedPane() {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        else { return }
        closePane(surface: current)
    }

    /// `close_tab:this` — close the whole active tab.
    func closeActiveTab() {
        if case let .terminal(id) = selection { closeTerminal(id) }
    }

    /// `resize_split` — grow the active pane by `amount` points in `direction`.
    func resizeSplit(_ direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction, amount: UInt16) {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf(),
              let node = tab.surfaceTree.root?.node(view: current) else { return }
        let bounds = CGRect(origin: .zero, size: tab.surfaceTree.viewBounds())
        if let newTree = try? tab.surfaceTree.resizing(node: node, by: amount, in: direction, with: bounds) {
            tab.surfaceTree = newTree
        }
    }

    /// Toggle focus mode (⌘⇧M) for the active terminal tab.
    func toggleFocusMode() {
        guard let tab = activeTerminal else { return }
        withAnimation(.smooth(duration: 0.2)) {
            focusMode.toggle()
        }
        if focusMode {
            focusModeSurfaceID = tab.focusedSurface?.id
                ?? tab.surfaceTree.root?.leftmostLeaf().id
        }
    }

    func selectFocusModePane(_ surface: Ghostty.SurfaceView) {
        focusModeSurfaceID = surface.id
        Ghostty.moveFocus(to: surface)
    }

    /// Close a terminal tab, selecting a sensible neighbor afterward.
    func closeTerminal(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        // Tear down any SSH connection popups bound to this tab's panes.
        for surface in terminals[idx].surfaceTree.root?.leaves() ?? [] {
            teardownConnection(surfaceID: surface.id)
        }
        recordClosed(terminals[idx], at: idx)
        terminals.remove(at: idx)
        guard case let .terminal(selected) = selection, selected == id else { return }
        if terminals.isEmpty {
            selection = .dashboard
            // The closed surface was the window's first responder. Once it's
            // gone the responder chain dangles and the dashboard's SwiftUI
            // controls stop receiving mouse/keyboard events. Reset the window's
            // first responder so the dashboard is interactive again.
            resetWindowFirstResponder()
        } else {
            selection = .terminal(terminals[min(idx, terminals.count - 1)].id)
        }
    }

    /// Record a closed tab (retaining it) so it can be reopened later. Newest
    /// entries are kept; the oldest are evicted past `maxClosedTabs`, which
    /// releases their surface trees and terminates the child processes.
    private func recordClosed(_ tab: TerminalTab, at index: Int) {
        closedTabs.append((tab, index))
        if closedTabs.count > maxClosedTabs {
            closedTabs.removeFirst(closedTabs.count - maxClosedTabs)
        }
    }

    /// Reopen the most recently closed tab at (close to) its original position,
    /// restoring its exact session. Returns the reopened tab, or nil if there's
    /// nothing to reopen. Backs the reopen-closed-tab shortcut and the
    /// "Reopen Closed Tab" command-palette entry.
    @discardableResult
    func reopenLastClosedTab() -> TerminalTab? {
        guard let entry = closedTabs.popLast() else { return nil }
        let tab = entry.tab
        let insertIndex = min(max(0, entry.index), terminals.count)
        terminals.insert(tab, at: insertIndex)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()
        if let surface = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf() {
            Ghostty.moveFocus(to: surface)
        }
        return tab
    }

    /// Reset the Vaults window's first responder to its content view. Used when
    /// the active terminal closes so the dashboard regains event handling.
    private func resetWindowFirstResponder() {
        DispatchQueue.main.async {
            guard let window = HostManagerController.shared.window else { return }
            window.makeFirstResponder(window.contentView)
        }
    }

    /// Duplicate a tab (right-click → Duplicate Tab). An SSH/command tab
    /// re-runs its launch command; a local tab opens a fresh shell at the
    /// focused pane's current directory.
    func duplicateTab(_ id: UUID) {
        guard let tab = terminals.first(where: { $0.id == id }) else { return }
        if let command = tab.launchCommand {
            // An SSH tab is a fresh connection, so run it through the staged
            // connection popup just like connecting from the hosts list — it's
            // not a local shell we can clone in place.
            let staged = command.hasPrefix("ssh ")
            newTerminal(command: command, name: tab.displayName, host: tab.connectHost, staged: staged)
            return
        }
        // Local shell: reopen in the focused pane's cwd (set at spawn, not via
        // a typed `cd` that the shell's login startup can swallow).
        let cwd = (tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf())?.pwd
        newTerminal(command: nil, name: tab.displayName, workingDirectory: cwd)
    }

    /// Rename a tab (right-click → Rename Tab…). Empty clears the override.
    /// Save (or RE-save) a tab's layout as a session — the one prompt used by
    /// the tab context menu and the Save Session keybind (⌘S by default).
    ///
    /// A tab already linked to a session overwrites it by default; a "Save as
    /// new session" checkbox forks instead. The tab is always renamed to the
    /// session name (issue #6).
    @MainActor
    func promptSaveSession(for tab: TerminalTab) {
        let existing = tab.sessionID.flatMap { id in
            SavedSessionsStore.shared.sessions.first { $0.id == id }
        }
        SarvAlert.present(
            title: "Save Session",
            message: existing == nil
                ? "Save this tab's split layout so you can reopen it later — local panes reopen at their directory and SSH panes reconnect."
                : "This tab is saved as “\(existing?.name ?? "")”. Saving updates that session with the current layout.",
            buttons: [
                .init("Save", isDefault: true),
                .init("Cancel", isCancel: true),
            ],
            rememberTitle: existing == nil ? nil : "Save as new session",
            rememberInitial: false,
            inputInitial: existing?.name ?? tab.displayName) { [weak self] result in
            guard let self, result.buttonIndex == 0,
                  var session = self.makeSavedSession(from: tab, name: result.inputText) else { return }
            session.linkTabName = true
            if let existing, !result.rememberChecked {
                // Overwrite the linked session in place (keep its identity).
                session.id = existing.id
                session.createdAt = existing.createdAt
            }
            SavedSessionsStore.shared.upsert(session)
            tab.sessionID = session.id
            // The tab always follows the session name.
            self.renameTab(tab.id, to: session.name)
        }
    }

    func renameTab(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        terminals.first { $0.id == id }?.customName = trimmed.isEmpty ? nil : trimmed
    }

    /// Rename every open tab linked to `sessionID` — used when a saved session
    /// with a linked tab name is renamed.
    func renameTabs(sessionID: UUID, to name: String) {
        for tab in terminals where tab.sessionID == sessionID {
            renameTab(tab.id, to: name)
        }
    }

    /// Set (or clear, with nil) a tab's accent color.
    func setColor(_ color: Color?, for id: UUID) {
        terminals.first { $0.id == id }?.color = color
    }

    /// Close every terminal tab except `id` (right-click → Close Other Tabs).
    func closeOtherTabs(keep id: UUID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        for (i, t) in terminals.enumerated() where t.id != id { recordClosed(t, at: i) }
        terminals.removeAll { $0.id != id }
        selection = .terminal(id)
    }

    /// Close all tabs positioned after `id` (right-click → Close Tabs to the Right).
    func closeTabsToRight(of id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        let removed = Set(terminals[(idx + 1)...].map(\.id))
        guard !removed.isEmpty else { return }
        for (i, t) in terminals.enumerated() where removed.contains(t.id) { recordClosed(t, at: i) }
        terminals.removeAll { removed.contains($0.id) }
        if case let .terminal(selected) = selection, removed.contains(selected) {
            selection = .terminal(id)
        }
    }

    /// Apply a resize/drop operation from the split-tree view to a tab.
    func performSplitOperation(_ op: TerminalSplitOperation, in tab: TerminalTab) {
        switch op {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            if let newTree = try? tab.surfaceTree.replacing(node: resize.node, with: resized) {
                tab.surfaceTree = newTree
            }
        case .drop(let drop):
            // Same-tab pane move only (single window).
            guard let sourceNode = tab.surfaceTree.root?.node(view: drop.payload) else { return }
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
            case .top: .up
            case .bottom: .down
            case .left: .left
            case .right: .right
            }
            let without = tab.surfaceTree.removing(sourceNode)
            if let newTree = try? without.inserting(view: drop.payload, at: drop.destination, direction: direction) {
                tab.surfaceTree = newTree
                Ghostty.moveFocus(to: drop.payload)
            }
        }
    }

    // MARK: - libghostty notification handling

    /// True when `id` is the selected terminal tab AND the app is frontmost —
    /// i.e. the user can actually see it, so it needs no attention dot or banner.
    /// When the app is in the background, even the selected tab isn't visible, so
    /// we still flag it (the user notices it on return).
    private func isTabOnScreen(_ id: UUID) -> Bool {
        selection == .terminal(id) && NSApp.isActive
    }

    /// A surface rang the bell — Claude Code (and most TUIs) ring it when they
    /// finish a turn or need a yes/no answer. If the ringing tab isn't the one
    /// on screen, flag it and post a notification so the user can find which of
    /// many tabs is waiting.
    private func handleBell(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: surface) else { return }
        let name = tab.displayName
        let id = tab.id
        Task { @MainActor in
            // Re-check on the main actor: the user may have switched to this tab
            // between the bell firing and this running. Claude Code fires a bell
            // AND an OSC notification, so a late task could otherwise re-flag a tab
            // the user just opened (selection's didSet already cleared it) — which
            // is what put a stray attention dot on the current tab. Never flag or
            // banner the tab that's actually on screen.
            guard !self.isTabOnScreen(id) else { return }
            self.attentionTabs.insert(id)
            SarvNotifications.shared.notify(.tabAttention(tab: name, tabID: id))
        }
    }

    /// A surface emitted an OSC desktop notification with a message (e.g.
    /// Claude Code's "needs your permission to…"). Surface the message, naming
    /// the tab, and flag it — unless that tab is on screen with the app focused.
    private func handleSurfaceNotification(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: surface) else { return }
        let body = (note.userInfo?["body"] as? String) ?? (note.userInfo?["title"] as? String) ?? ""
        guard !body.isEmpty else { return }
        let name = tab.displayName
        let id = tab.id
        Task { @MainActor in
            // Same rule as the bell: never flag or banner the tab that's on screen,
            // re-checked here because the selection may have changed since the OSC
            // notification arrived.
            guard !self.isTabOnScreen(id) else { return }
            self.attentionTabs.insert(id)
            SarvNotifications.shared.notify(.tabMessage(tab: name, message: body, tabID: id))
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note)
            })
        }

        observe(Ghostty.Notification.ghosttyCloseSurface) { [weak self] in self?.handleClose($0) }
        observe(Ghostty.Notification.ghosttyNewSplit) { [weak self] in self?.handleNewSplit($0) }
        observe(Ghostty.Notification.ghosttyFocusSplit) { [weak self] in self?.handleFocusSplit($0) }
        observe(Ghostty.Notification.didEqualizeSplits) { [weak self] in self?.handleEqualize($0) }
        observe(Ghostty.Notification.didToggleSplitZoom) { [weak self] in self?.handleToggleZoom($0) }
        // These fire only for CUSTOM keybinds (the default combos are consumed by
        // AppDelegate's monitor before reaching the surface). libghostty matches
        // the user's config and posts here; we perform the single-window action.
        observe(Ghostty.Notification.ghosttyGotoTab) { [weak self] in self?.handleGotoTab($0) }
        observe(.ghosttyMoveTab) { [weak self] in self?.handleMoveTab($0) }
        observe(Ghostty.Notification.didResizeSplit) { [weak self] in self?.handleResizeSplitNote($0) }
        observe(Ghostty.Notification.ghosttyToggleFullscreen) { [weak self] in self?.handleToggleFullscreen($0) }
        observe(.ghosttyBellDidRing) { [weak self] in self?.handleBell($0) }  // tab needs attention
        observe(.sarvSurfaceDesktopNotification) { [weak self] in self?.handleSurfaceNotification($0) }
        observe(.ghosttyCloseTab) { [weak self] in self?.handleCloseTabNote($0, kind: .this) }
        observe(.ghosttyCloseOtherTabs) { [weak self] in self?.handleCloseTabNote($0, kind: .other) }
        observe(.ghosttyCloseTabsOnTheRight) { [weak self] in self?.handleCloseTabNote($0, kind: .right) }
        // App-wide config change (Settings save / live reload). libghostty
        // applies new config to NEW surfaces, but our existing embedded surfaces
        // need an explicit push so live changes (cursor, colors, font, padding…)
        // take effect without relaunching. Deferred so `ghostty.config` is the
        // freshly-applied config by the time we read it.
        observe(.ghosttyConfigDidChange) { [weak self] note in
            guard note.object == nil else { return }
            DispatchQueue.main.async {
                self?.applyConfigToExistingSurfaces()
                // A config reload pushes the base config, dropping our per-display
                // weight override — re-apply it.
                self?.applyFontWeightForDisplay()
            }
        }

        // Per-display font weight: each surface posts when its backing scale
        // changes (creation + moving to another screen), and the setting toggle
        // re-applies to all.
        observe(.sarvSurfaceBackingChanged) { [weak self] note in
            guard let pane = note.object as? Ghostty.SurfaceView else { return }
            self?.applyFontWeight(to: pane)
            // Fires at surface creation too — new panes need the readability
            // pass when a shared background image is showing.
            self?.applySmartThemeIfNeeded(to: pane)
        }
        observe(.sarvAutoFontWeightChanged) { [weak self] _ in self?.applyFontWeightForDisplay() }
    }

    /// Whether to auto-adjust font weight to the display density. Default ON.
    private var autoFontWeightEnabled: Bool {
        UserDefaults.standard.object(forKey: "SarvAutoFontWeight") == nil
            ? true : UserDefaults.standard.bool(forKey: "SarvAutoFontWeight")
    }

    /// Re-apply per-display font weight to every open terminal surface.
    /// (Called on the main queue from notification observers.)
    func applyFontWeightForDisplay() {
        for tab in terminals {
            for pane in tab.surfaceTree.root?.leaves() ?? [] { applyFontWeight(to: pane) }
        }
    }

    /// Adjust one surface's font weight to the screen it's on: thicken on a low-DPI
    /// (≤1×) screen so text stays crisp, plain on a Retina (2×) screen so it isn't
    /// chunky. Surfaces with a per-host theme are skipped — their theme owns the
    /// surface config and we must not clobber it. With auto-weight off, the user's
    /// own configured weight is restored.
    private func applyFontWeight(to pane: Ghostty.SurfaceView) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty,
              let surface = pane.surface else { return }
        let host = connections[pane.id]?.model.host ?? tab(containing: pane)?.connectHost
        if !((host?.themeName.trimmingCharacters(in: .whitespaces).isEmpty) ?? true) { return }
        let scale = pane.window?.backingScaleFactor
            ?? HostManagerController.shared.window?.backingScaleFactor ?? 2
        if autoFontWeightEnabled {
            ghostty.applyFontThicken(scale < 2, to: surface)
        } else {
            ghostty.reloadConfig(surface: surface, soft: true)   // restore user's weight
        }
    }

    /// Push the current config to every live embedded surface so settings apply
    /// immediately to existing terminals, not just newly-opened ones. After the
    /// base push, re-run the readability pass (`applySmartThemeIfNeeded`) — the
    /// push drops per-surface overrides, and a newly set background image needs
    /// the text-contrast check.
    private func applyConfigToExistingSurfaces() {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        for tab in terminals {
            for pane in tab.surfaceTree.root?.leaves() ?? [] {
                guard let surface = pane.surface else { continue }
                ghostty.reloadConfig(surface: surface, soft: true)
                applySmartThemeIfNeeded(to: pane)
            }
        }
    }

    /// The ONE readability-aware theme entry point for a pane: the host theme
    /// when the tab has one, else the global theme when a shared background
    /// image is showing (the image can wash out the theme's text). Both cases
    /// funnel into `applyThemeSmart` — never re-implement this decision.
    private func applySmartThemeIfNeeded(to pane: Ghostty.SurfaceView) {
        let host = connections[pane.id]?.model.host ?? tab(containing: pane)?.connectHost
        let hostTheme = host?.themeName.trimmingCharacters(in: .whitespaces) ?? ""
        if !hostTheme.isEmpty {
            DispatchQueue.main.async { self.applyThemeSmart(hostTheme, to: pane) }
            return
        }
        guard BackgroundDisplayStore.shared.hasSharedImage,
              let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty,
              let global = ghostty.config.themeName?.trimmingCharacters(in: .whitespaces),
              !global.isEmpty else { return }
        DispatchQueue.main.async { self.applyThemeSmart(global, to: pane) }
    }

    private enum CloseTabKind { case this, other, right }

    private func handleGotoTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView, tab(containing: surface) != nil,
              let tabEnum = note.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e
        else { return }
        let raw = tabEnum.rawValue
        if raw == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue { cycleTab(-1) }
        else if raw == GHOSTTY_GOTO_TAB_NEXT.rawValue { cycleTab(1) }
        else if raw == GHOSTTY_GOTO_TAB_LAST.rawValue { selectLastTab() }
        else if raw >= 1 { selectTab(index: min(Int(raw) - 1, terminals.count - 1)) }
    }

    private func handleMoveTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface),
              let action = note.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab,
              action.amount != 0,
              let from = terminals.firstIndex(where: { $0.id == t.id }) else { return }
        let target = max(0, min(terminals.count - 1, from + action.amount))
        guard target != from else { return }
        withAnimation(.smooth(duration: 0.2)) {
            let moved = terminals.remove(at: from)
            terminals.insert(moved, at: target)
        }
    }

    private func handleResizeSplitNote(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface),
              let node = t.surfaceTree.root?.node(view: surface),
              let dir = note.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] as? Ghostty.SplitResizeDirection,
              let amount = note.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] as? UInt16 else { return }
        let spatial: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch dir {
        case .up: spatial = .up
        case .down: spatial = .down
        case .left: spatial = .left
        case .right: spatial = .right
        }
        let bounds = CGRect(origin: .zero, size: t.surfaceTree.viewBounds())
        if let newTree = try? t.surfaceTree.resizing(node: node, by: amount, in: spatial, with: bounds) {
            t.surfaceTree = newTree
        }
    }

    private func handleToggleFullscreen(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView, tab(containing: surface) != nil else { return }
        surface.window?.toggleFullScreen(nil)
    }

    private func handleCloseTabNote(_ note: Notification, kind: CloseTabKind) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface) else { return }
        switch kind {
        case .this: closeTerminal(t.id)
        case .other: closeOtherTabs(keep: t.id)
        case .right: closeTabsToRight(of: t.id)
        }
    }

    private func handleNewSplit(_ note: Notification) {
        guard let src = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: src),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        guard let dirAny = note.userInfo?["direction"],
              let dir = dirAny as? ghostty_action_split_direction_e else { return }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch dir {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: direction = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT:  direction = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN:  direction = .down
        case GHOSTTY_SPLIT_DIRECTION_UP:    direction = .up
        default: return
        }
        let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        let newView = Ghostty.SurfaceView(app, baseConfig: config)
        guard let newTree = try? tab.surfaceTree.inserting(view: newView, at: src, direction: direction) else { return }
        tab.surfaceTree = newTree
        Ghostty.moveFocus(to: newView, from: src)
    }

    private func handleClose(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        // An SSH pane must NEVER auto-close when its ssh PROCESS exits — e.g. ssh
        // quitting after a wrong password, or a session that dropped. Keep the
        // surface so its connection popup shows the error / "Session ended" and
        // offers reconnect. `process_alive == false` means the process died on
        // its own (not a user close); an explicit user close arrives with the
        // process still alive and is allowed to fall through. Only the tab × or
        // the card's Close button (via closeTerminal / closePane) tears it down.
        let processAlive = (note.userInfo?["process_alive"] as? Bool) ?? false
        if !processAlive, let conn = connections[surface.id] {
            conn.controller.handleProcessExited()
            return
        }
        awaitingChoice.remove(surface.id)
        let remaining = tab.surfaceTree.removing(node)
        if remaining.isEmpty {
            closeTerminal(tab.id)
        } else {
            tab.surfaceTree = remaining
            if let next = remaining.root?.leftmostLeaf() {
                Ghostty.moveFocus(to: next)
            }
        }
    }

    private func handleFocusSplit(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target),
              let targetNode = tab.surfaceTree.root?.node(view: target),
              let dirAny = note.userInfo?[Ghostty.Notification.SplitDirectionKey],
              let direction = dirAny as? Ghostty.SplitFocusDirection,
              let next = tab.surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode)
        else { return }
        Ghostty.moveFocus(to: next, from: target)
    }

    private func handleEqualize(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target) else { return }
        tab.surfaceTree = tab.surfaceTree.equalized()
    }

    private func handleToggleZoom(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target),
              let node = tab.surfaceTree.root?.node(view: target) else { return }
        if tab.surfaceTree.zoomed != nil {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: nil)
        } else {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: node)
        }
    }
}

// MARK: - Saved sessions

extension VaultsTabsModel {
    /// Map a tab color back to its preset option id (for persistence).
    private func colorOptionID(for color: Color) -> String? {
        Self.tabColorOptions.first { $0.color == color }?.id
    }

    /// Resolve a preset color option id back to its `Color`.
    private func color(forOptionID id: String) -> Color? {
        Self.tabColorOptions.first { $0.id == id }?.color
    }

    // MARK: Snapshot (save)

    /// Build a `SavedSession` snapshot of a tab's live split layout. Captures the
    /// tree shape + ratios and, per pane, whether it's a local shell (with its
    /// cwd) or an SSH session (its saved-host id and/or command).
    func makeSavedSession(from tab: TerminalTab, name: String) -> SavedSession? {
        guard let root = tab.surfaceTree.root else { return nil }
        let now = Date()
        return SavedSession(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            updatedAt: now,
            colorID: tab.color.flatMap { colorOptionID(for: $0) },
            layout: savedNode(from: root, tab: tab))
    }

    private func savedNode(
        from node: SplitTree<Ghostty.SurfaceView>.Node,
        tab: TerminalTab
    ) -> SavedSession.PaneNode {
        switch node {
        case .leaf(let view):
            return .leaf(savedPane(for: view, tab: tab))
        case .split(let split):
            let direction: SavedSession.PaneNode.Direction =
                split.direction == .horizontal ? .horizontal : .vertical
            return .split(.init(
                direction: direction,
                ratio: split.ratio,
                left: savedNode(from: split.left, tab: tab),
                right: savedNode(from: split.right, tab: tab)))
        }
    }

    private func savedPane(for view: Ghostty.SurfaceView, tab: TerminalTab) -> SavedSession.Pane {
        // A manual rename (Change Terminal Title) wins, matching the pane
        // header; otherwise the sticky override, then the live title.
        let title = view.isUserTitled && !view.title.isEmpty
            ? view.title
            : tab.paneTitleOverrides[view.id] ?? (view.title.isEmpty ? nil : view.title)
        // A pane with a live SSH connection is saved as SSH; everything else
        // (plain shells, unresolved choosers) is saved as a local shell.
        if let conn = connections[view.id] {
            return .init(
                kind: .ssh,
                workingDirectory: nil,
                hostID: conn.model.host?.id,
                command: conn.command,
                // Fall back to the host label so an SSH pane keeps its name even
                // if no explicit override was recorded (the live title is ghost).
                title: title ?? conn.model.host?.displayLabel)
        }
        // A single-pane tab launched as a quick-connect `ssh …` with no staged
        // connection registered — preserve it as SSH so it reconnects on restore
        // rather than falling back to a bare local shell.
        if case .leaf(let rootView)? = tab.surfaceTree.root,
           rootView.id == view.id,
           let cmd = tab.launchCommand, cmd.hasPrefix("ssh ") {
            return .init(
                kind: .ssh,
                workingDirectory: nil,
                hostID: tab.connectHost?.id,
                command: cmd,
                title: title)
        }
        return .init(
            kind: .local,
            workingDirectory: view.pwd,
            hostID: nil,
            command: nil,
            title: title)
    }

    // MARK: Restore (open)

    /// Reopen a saved session as a new tab, recreating its split layout: each
    /// local pane respawns at its saved cwd and each SSH pane auto-connects.
    func openSavedSession(_ session: SavedSession) {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }

        // Build the surface tree up front. Local panes spawn directly in their
        // saved cwd; SSH panes start as blank placeholders we connect once the
        // tab is mounted (so the per-surface connection registry can find them).
        var sshPanes: [(surface: Ghostty.SurfaceView, pane: SavedSession.Pane)] = []
        var titleOverrides: [UUID: String] = [:]
        let root = buildNode(session.layout, app: app, sshPanes: &sshPanes, titleOverrides: &titleOverrides)

        let tab = TerminalTab(tree: SplitTree(root: root, zoomed: nil),
                              name: uniqueTabName(base: session.name))
        // Restart snapshots carry the ORIGINAL library-session link; sessions
        // opened from the Saved Sessions list link to themselves.
        tab.sessionID = session.linkedSessionID ?? session.id
        tab.paneTitleOverrides = titleOverrides
        tab.color = session.colorID.flatMap { color(forOptionID: $0) }
        terminals.append(tab)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()
        if let first = tab.surfaceTree.root?.leftmostLeaf() {
            Ghostty.moveFocus(to: first)
        }

        // Kick off SSH connections after the tree is mounted.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (surface, pane) in sshPanes {
                if let hostID = pane.hostID,
                   let host = SavedHostsStore.shared.host(withID: hostID) {
                    self.connectSavedHostInPane(host: host, surface: surface)
                } else if let command = pane.command, !command.isEmpty {
                    // No saved host (or it was deleted): run the raw ssh command
                    // in the placeholder shell; ssh prompts on the TTY as needed.
                    self.send(command, to: surface)
                }
            }
        }
    }

    private func buildNode(
        _ node: SavedSession.PaneNode,
        app: ghostty_app_t,
        sshPanes: inout [(surface: Ghostty.SurfaceView, pane: SavedSession.Pane)],
        titleOverrides: inout [UUID: String]
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch node {
        case .leaf(let pane):
            let surface: Ghostty.SurfaceView
            switch pane.kind {
            case .local:
                if let cwd = pane.workingDirectory, !cwd.isEmpty {
                    var cfg = Ghostty.SurfaceConfiguration()
                    cfg.workingDirectory = cwd
                    surface = Ghostty.SurfaceView(app, baseConfig: cfg)
                } else {
                    surface = Ghostty.SurfaceView(app)
                }
            case .ssh:
                // Blank placeholder; connected after the tab mounts.
                surface = Ghostty.SurfaceView(app)
                sshPanes.append((surface, pane))
            }
            if let title = pane.title { titleOverrides[surface.id] = title }
            return .leaf(view: surface)

        case .split(let split):
            let direction: SplitTree<Ghostty.SurfaceView>.Direction =
                split.direction == .horizontal ? .horizontal : .vertical
            let left = buildNode(split.left, app: app, sshPanes: &sshPanes, titleOverrides: &titleOverrides)
            let right = buildNode(split.right, app: app, sshPanes: &sshPanes, titleOverrides: &titleOverrides)
            return .split(.init(direction: direction, ratio: split.ratio, left: left, right: right))
        }
    }
}
