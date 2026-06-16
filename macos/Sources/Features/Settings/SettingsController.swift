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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        window.contentViewController = containerVC

        super.init(window: window)

        window.delegate = self

        // Our own sidebar toggle pinned to the leading edge of the titlebar.
        // Stays in the same place whether the sidebar is shown or hidden.
        let toggleAccessory = NSTitlebarAccessoryViewController()
        toggleAccessory.layoutAttribute = .leading
        toggleAccessory.view = NSHostingView(rootView: SidebarToggleButton { [weak containerVC] in
            containerVC?.toggleSidebar(nil)
        })
        window.addTitlebarAccessoryViewController(toggleAccessory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported.")
    }

    func show() {
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
