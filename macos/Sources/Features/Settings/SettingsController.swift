import Foundation
import Cocoa
import SwiftUI

/// Hosts the Settings window. Singleton — `SettingsController.shared.show()` from anywhere.
///
/// The window's content is an `NSSplitViewController` (via
/// `SettingsContainerViewController`) wrapping SwiftUI sub-views. We use the
/// AppKit primitive instead of SwiftUI's `NavigationSplitView` to get a
/// fixed-position sidebar toggle and clean animation.
class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared: SettingsController = SettingsController()

    private let containerVC = SettingsContainerViewController()

    private init() {
        // Chromeless, non-resizable window: it covers the main window like a
        // full-screen takeover (no traffic lights / minimize / resize) and is
        // dismissed only by the in-content "Done" (✕) button — not a popup.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.contentViewController = containerVC

        super.init(window: window)

        window.delegate = self

        // Our own sidebar toggle pinned to the leading edge of the titlebar.
        // Titlebar-accessory hosting views need an explicit frame — without one
        // a SwiftUI NSHostingView can collapse to zero size and vanish.
        let toggleAccessory = NSTitlebarAccessoryViewController()
        toggleAccessory.layoutAttribute = .leading
        let toggleView = NSHostingView(rootView: SidebarToggleButton { [weak containerVC] in
            containerVC?.toggleSidebar(nil)
        })
        toggleView.frame = NSRect(x: 0, y: 0, width: 44, height: 28)
        toggleAccessory.view = toggleView
        window.addTitlebarAccessoryViewController(toggleAccessory)

        // Trailing "Done" (✕) button — the only way to dismiss; returns to the
        // previous screen.
        let closeAccessory = NSTitlebarAccessoryViewController()
        closeAccessory.layoutAttribute = .trailing
        let doneView = NSHostingView(rootView: SettingsDoneButton { [weak self] in self?.hide() })
        doneView.frame = NSRect(x: 0, y: 0, width: 44, height: 28)
        closeAccessory.view = doneView
        window.addTitlebarAccessoryViewController(closeAccessory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported.")
    }

    func show() {
        // Snapshot current values so per-section "Revert" undoes only the
        // changes made during this visit.
        containerVC.viewModel.captureBaselines()
        // Cover the main window's frame so it reads as a full takeover, not a
        // floating popup.
        if let window, let main = HostManagerController.shared.window {
            window.setFrame(main.frame, display: true)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.close()
    }

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    @objc func cancel(_ sender: Any?) {
        hide()
    }
}

/// Pinned sidebar toggle. Lives in a titlebar accessory; matches the
/// SF Symbol style of other AppKit window accessories.
private struct SidebarToggleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Toggle Sidebar")
        .frame(width: 28, height: 28)
        .padding(.leading, 8)
    }
}

/// Trailing "Done" (✕) button that closes the Settings takeover.
private struct SettingsDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close settings (Esc)")
        .frame(height: 28)
        .padding(.trailing, 10)
    }
}
