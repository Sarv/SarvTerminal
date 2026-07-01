import Foundation
import Cocoa
import SwiftUI

/// Floating panel for the host-search palette. Singleton.
///
/// The NSEvent key monitor lives here (not inside the SwiftUI view) so
/// installation/removal is anchored to the panel's show/hide. Previously
/// the monitor was installed via `.onAppear` and removed via `.onDisappear`,
/// but `.onDisappear` doesn't reliably fire when the panel is hidden by
/// `hidesOnDeactivate`, which left a global keyDown monitor active and
/// swallowed Enter presses in the terminal.
/// NSPanel subclass that can become the key window even when
/// chromeless. Default `NSPanel` + `.titled` is fine, but we keep the
/// explicit override to ensure key activation in every macOS version.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HostSearchController: NSWindowController, NSWindowDelegate {
    static let shared: HostSearchController = HostSearchController()

    private let model = HostSearchModel()
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var globalClickMonitor: Any?

    private init() {
        // `.titled` (chrome hidden via the flags below) lets the panel become
        // key, so Esc / arrows / Enter routing all work. Dropping
        // `.nonactivatingPanel` ensures the app actually focuses the panel
        // (otherwise it stays "invisible to focus" and keyDown events go to
        // the previously-key terminal window, which is what caused Esc to
        // do nothing).
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: HostSearchPalette(
            model: model,
            onRun: { [weak self] action in self?.run(action) }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported.")
    }

    func show() {
        model.loadHosts()
        model.reset()
        positionOverActiveWindow()
        installKeyMonitor()
        installOutsideClickMonitors()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Panel is key now — ask the SwiftUI field to take focus so typing lands
        // there immediately (onAppear only fires on the first show of this reused
        // panel, so the model token drives focus on every subsequent open).
        model.requestSearchFocus()
    }

    func hide() {
        removeKeyMonitor()
        removeOutsideClickMonitors()
        window?.orderOut(nil)
    }

    /// AppKit hides our panel when it resigns key (we set
    /// `hidesOnDeactivate`). Make sure the monitors go with it.
    func windowDidResignKey(_ notification: Notification) {
        removeKeyMonitor()
        removeOutsideClickMonitors()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        removeOutsideClickMonitors()
    }

    // MARK: - Positioning

    private func positionOverActiveWindow() {
        guard let panel = window else { return }
        let size = panel.frame.size
        if let active = NSApp.keyWindow ?? NSApp.mainWindow, active != panel {
            let parent = active.frame
            panel.setFrameOrigin(NSPoint(
                x: parent.midX - size.width / 2,
                y: parent.midY - size.height / 2
            ))
        } else {
            panel.center()
        }
    }

    // MARK: - Key handling

    private func installKeyMonitor() {
        // Defensive: never stack two monitors.
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible else { return event }
            // While the palette is up it OWNS keyboard input. We deliberately do
            // NOT require `event.window === panel`: the panel isn't always the
            // key window (SwiftUI focus in a reused NSPanel is unreliable), and
            // that check was silently dropping every keystroke — so typing never
            // reached the search field. The outside-click monitor dismisses the
            // palette, so capturing keys whenever it's visible is safe.

            // All model mutations are dispatched to the main queue (a fresh
            // runloop tick) rather than mutated inline in this event-monitor
            // callback: mutating the @Published state inside the key-event
            // callback did NOT schedule SwiftUI's re-render (the list stayed
            // stale and arrows didn't move, even though the model updated —
            // proven by Enter acting on the typed query). The async hop lets
            // SwiftUI observe the change and re-render normally.
            switch event.keyCode {
            case 125: // ↓
                DispatchQueue.main.async { self.model.stepHighlight(+1) }
                return nil
            case 126: // ↑
                DispatchQueue.main.async { self.model.stepHighlight(-1) }
                return nil
            case 36, 76: // Return / Keypad Enter
                if let row = self.model.confirmSelection() {
                    self.run(row.action)
                }
                return nil
            case 53: // Esc
                self.hide()
                return nil
            case 51: // Delete / Backspace
                DispatchQueue.main.async {
                    if !self.model.search.isEmpty { self.model.search.removeLast() }
                }
                return nil
            default:
                if event.modifierFlags.contains(.command) {
                    // ⌘V pastes into the query; other ⌘-shortcuts pass through.
                    if event.charactersIgnoringModifiers == "v",
                       let pasted = NSPasteboard.general.string(forType: .string) {
                        DispatchQueue.main.async { self.model.search += pasted }
                        return nil
                    }
                    return event
                }
                if let chars = event.characters, !chars.isEmpty,
                   chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    DispatchQueue.main.async { self.model.search += chars }
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Two monitors so click-outside dismisses the palette: a LOCAL monitor
    /// for clicks inside our own app (the terminal window) and a GLOBAL
    /// monitor for clicks in other apps.
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible else { return event }
            if event.window !== panel { self.hide() }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeOutsideClickMonitors() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    // MARK: - Run palette actions

    /// Dispatch the confirmed palette row to a new embedded terminal tab.
    private func run(_ action: PaletteAction) {
        hide()
        switch action {
        case .host(let host):
            VaultsTabsModel.shared.newTerminal(command: host.sshCommand, name: host.label)
        case .savedHost(let host):
            // Go through the staged connection popup (askpass + saved password +
            // auto-reconnect) instead of a bare ssh command.
            HostConnect.run(
                command: host.sshCommand(staged: true),
                name: host.displayLabel,
                host: host,
                staged: true)
        case .quickConnect(let query):
            let target = query.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return }
            // Already prefixed with `ssh`? Run as-is; otherwise wrap it.
            let command = target.hasPrefix("ssh ") ? target : "ssh \(target)"
            VaultsTabsModel.shared.newTerminal(command: command, name: target)
        case .localTerminal:
            VaultsTabsModel.shared.newTerminal(command: nil, name: "Terminal")
        case .serial:
            // Show the Vaults dashboard and open the serial connect sheet there.
            VaultsTabsModel.shared.selectDashboard(section: .vaults)
            VaultsTabsModel.shared.presentingSerialConnect = true
        }
    }
}
