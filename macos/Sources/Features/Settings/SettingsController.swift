import Foundation
import Cocoa
import SwiftUI

/// A borderless window that can still take keyboard focus. Borderless windows
/// default to `canBecomeKey == false`, which would stop the hosted SwiftUI text
/// fields from ever becoming first responder.
final class SettingsOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the Settings window. Singleton — `SettingsController.shared.show()` from anywhere.
///
/// The window is **borderless** and covers the presenting window's entire frame,
/// so it reads as a full takeover with nothing (not even the tab strip, which
/// lives at the top of the Vaults content) left exposed behind it. Because there
/// is no titlebar, the sidebar toggle and close button live in an in-content
/// header bar (see `SettingsHeaderBar`). The content is an `NSSplitViewController`
/// (via `SettingsContainerViewController`).
class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared: SettingsController = SettingsController()

    private let containerVC = SettingsContainerViewController()

    /// The window Settings was opened over. We return focus to exactly this
    /// window on close — the current terminal tab / window, not always Vaults.
    private weak var presenter: NSWindow?

    private init() {
        // A standard, large, movable window with a NATIVE title bar: the three
        // traffic lights on the left and "Settings" as the title. Non-modal, so
        // clicking the terminal sends it behind and the user sees their changes
        // live; the toolbar / File-menu button brings it back.
        let window = SettingsOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        // Let AppKit maintain the key-view loop so Tab / Shift-Tab move focus
        // between the hosted SwiftUI text fields instead of doing nothing.
        window.autorecalculatesKeyViewLoop = true
        window.contentViewController = containerVC
        // Never let it shrink so small the body is clipped (the bug where the
        // window opened as a short slab).
        window.contentMinSize = NSSize(width: 900, height: 640)

        super.init(window: window)

        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported.")
    }

    /// Open Settings and jump to a specific section (used by notification
    /// "Show" actions, e.g. a sync failure routing to Settings ▸ Sync).
    func show(section: SettingsSection) {
        containerVC.viewModel.selectedSection = section
        show()
    }

    func show() {
        // Snapshot current values so per-section "Revert" undoes only the
        // changes made during this visit.
        containerVC.viewModel.captureBaselines()
        guard let window else { return }
        // Remember the window we're covering so we return to exactly it on close
        // (the current terminal tab / window, not always Vaults).
        let host = NSApp.keyWindow ?? HostManagerController.shared.window
        presenter = host
        // Show on whatever Space is currently active — including on top of a
        // full-screen terminal — so Settings never yanks the user to another
        // Space and closing it lands them right back where they were.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Always open CENTERED at a comfortable size — ignore any prior dragged
        // position, per request. (Keeps a larger size if the user grew it, but
        // never smaller than the minimum, and always re-centers.)
        let minSize = NSSize(width: 900, height: 640)
        let defaultSize = NSSize(width: 1100, height: 760)
        var size = window.frame.size
        if size.width < defaultSize.width { size.width = defaultSize.width }
        if size.height < defaultSize.height { size.height = defaultSize.height }
        size.width = max(size.width, minSize.width)
        size.height = max(size.height, minSize.height)
        let origin: NSPoint
        if let host, host !== window {
            origin = NSPoint(x: host.frame.midX - size.width / 2,
                             y: host.frame.midY - size.height / 2)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        } else {
            origin = window.frame.origin
        }
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.close()
    }

    @IBAction func close(_ sender: Any) {
        hide()
    }

    @objc func cancel(_ sender: Any?) {
        hide()
    }

    // MARK: - NSWindowDelegate

    /// Closing Settings is the commit point for settings sync: flush the whole
    /// editing session as a single version instead of pushing per change.
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .sarvSettingsClosed, object: nil)

        // Closing the takeover just reveals the window it was shown over.
        presenter?.makeKeyAndOrderFront(nil)
        presenter = nil
    }
}

/// Slim in-content bar holding just the sidebar toggle. The window now has a
/// native title bar (traffic lights + "Settings" title), so the title and close
/// button that used to live here are gone.
struct SettingsHeaderBar: View {
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}
