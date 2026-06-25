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
        // Borderless takeover: no titlebar, no traffic lights, covers the whole
        // presenting window. Dismissed only via the in-content ✕ (or Esc).
        let window = SettingsOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        // Let AppKit maintain the key-view loop so Tab / Shift-Tab move focus
        // between the hosted SwiftUI text fields instead of doing nothing.
        window.autorecalculatesKeyViewLoop = true
        window.contentViewController = containerVC

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
        // Cover the presenting window's full frame so nothing (e.g. the tab
        // strip) is left exposed behind or clickable.
        if let host, host !== window {
            window.setFrame(host.frame, display: true)
        }
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

/// In-content header for the borderless Settings window: sidebar toggle on the
/// leading edge, centered title, and the close (✕) button trailing. Replaces the
/// titlebar accessories a titled window would use.
struct SettingsHeaderBar: View {
    let onToggleSidebar: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text("Settings")
                .font(.headline)

            HStack(spacing: 0) {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Toggle Sidebar")

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close settings (Esc)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}
