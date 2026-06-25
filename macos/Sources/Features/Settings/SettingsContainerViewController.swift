import AppKit
import SwiftUI

/// Settings window content controller.
///
/// We use AppKit primitives (`NSSplitViewController` + `NSHostingController`)
/// instead of SwiftUI's `NavigationSplitView` to get:
///
/// 1. **Fixed-position sidebar toggle** (we attach our own button as a
///    titlebar accessory; it stays in the same spot regardless of sidebar
///    visibility).
/// 2. **No phantom `>>` flash** during sidebar animations. macOS's
///    `NSSplitViewController` animates cleanly; SwiftUI on macOS 13's
///    `NavigationSplitView` injects a secondary toggle that briefly appears
///    mid-transition.
/// 3. **Footer that lives at window level**, not inside a column — Save /
///    Revert never reflow with the sidebar.
final class SettingsContainerViewController: NSViewController {

    /// Shared state across sidebar / detail / footer.
    let viewModel = SettingsViewModel()

    // MARK: - Children

    private lazy var sidebarHosting: NSHostingController<SidebarView> = {
        NSHostingController(rootView: SidebarView(viewModel: viewModel))
    }()

    private lazy var detailHosting: NSHostingController<DetailView> = {
        NSHostingController(rootView: DetailView(viewModel: viewModel))
    }()

    private lazy var footerHosting: NSHostingView<FooterBarView> = {
        NSHostingView(rootView: FooterBarView(viewModel: viewModel))
    }()

    /// In-content header (the borderless window has no titlebar to host these):
    /// sidebar toggle + title + close.
    private lazy var headerHosting: NSHostingView<SettingsHeaderBar> = {
        NSHostingView(rootView: SettingsHeaderBar(
            onToggleSidebar: { [weak self] in self?.toggleSidebar(nil) },
            onClose: { SettingsController.shared.hide() }
        ))
    }()

    private lazy var splitVC: NSSplitViewController = {
        let vc = NSSplitViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        sidebarItem.preferredThicknessFraction = 0.26
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        vc.addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = 600
        detailItem.canCollapse = false
        vc.addSplitViewItem(detailItem)

        return vc
    }()

    // MARK: - View hierarchy

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Adopt the split VC as a child so menu actions like
        // "View → Show / Hide Sidebar" route correctly.
        addChild(splitVC)

        headerHosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerHosting)

        let headerDivider = NSBox()
        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerDivider)

        let splitView = splitVC.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        footerHosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerHosting)

        NSLayoutConstraint.activate([
            headerHosting.topAnchor.constraint(equalTo: root.topAnchor),
            headerHosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerHosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            headerDivider.topAnchor.constraint(equalTo: headerHosting.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            splitView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            divider.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            footerHosting.topAnchor.constraint(equalTo: divider.bottomAnchor),
            footerHosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerHosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerHosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
    }

    // MARK: - Sidebar toggle

    /// Called by the titlebar toggle button. Routes through
    /// `NSSplitViewController`'s built-in animated collapse logic.
    @objc func toggleSidebar(_ sender: Any?) {
        splitVC.toggleSidebar(sender)
    }
}
