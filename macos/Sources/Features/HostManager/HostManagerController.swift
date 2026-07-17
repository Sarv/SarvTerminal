import Foundation
import Cocoa
import SwiftUI
import Combine

/// Notification bell in the Vaults top strip. Opens the in-app inbox of
/// recent app-level notifications (transfers, tunnels, sync, etc.) and shows
/// an unread badge. (No gear next to it — Settings lives in the app menu, ⌘,.)
struct VaultsBellView: View {
    @ObservedObject private var center = SarvNotificationCenter.shared
    @State private var showInbox = false

    var body: some View {
        Button {
            showInbox.toggle()
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 14, weight: .regular))
                // Adapts to the chrome appearance — hardcoded .white vanishes
                // on a light window.
                .foregroundStyle(.secondaryText)
                .frame(width: 28, height: 24)
                .overlay(alignment: .topTrailing) {
                    if center.unreadCount > 0 {
                        Text(center.unreadCount > 99 ? "99+" : "\(center.unreadCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 7, y: -5)
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverTip("Notifications")
        .popover(isPresented: $showInbox, arrowEdge: .bottom) {
            NotificationsInboxView { showInbox = false }
        }
        .onChange(of: showInbox) { open in
            // While open, mark everything read and suppress count/sound for new
            // arrivals; closing re-arms the badge for future notifications.
            center.isInboxOpen = open
            if open { center.markAllRead() }
        }
    }
}

/// Hosts the **Vaults** window — the single window SarvTerminal lives in.
///
/// There is exactly one window. Its content area swaps between the Vaults
/// dashboard and embedded terminal surfaces, driven by `VaultsTabsModel` and
/// the custom `VaultsTabStrip`. Terminals are NOT separate windows and native
/// macOS window-tabbing is disabled (`tabbingMode = .disallowed`) — that's
/// what keeps the Termius-style layout stable. See the `vaults-window-tabbing`
/// memory for the history.
class HostManagerController: NSWindowController, NSWindowDelegate {
    static let shared: HostManagerController = HostManagerController()

    private init() {
        // Kill the native macOS window tab bar app-wide. It was showing as a
        // stray "…" row under our custom strip and intercepting tab drags.
        NSWindow.allowsAutomaticWindowTabbing = false

        let window = OpaqueWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Keep the window opaque even when panes are translucent (shared
        // background mode). Otherwise a translucent terminal composites against
        // the desktop behind the window instead of our window-level image, and
        // the tab bar stops rendering. With an opaque window the panes blend
        // against the SwiftUI content (the shared image) instead.
        window.isOpaque = true
        // A dark gray rather than pure black: the titlebar is transparent, so
        // this color shows behind the traffic-light buttons. macOS dims those
        // buttons to a translucent gray when the window is inactive, which is
        // invisible on pure black — a dark gray keeps them visible. Value ~#1F1F1F
        // matches the Claude app's dark titlebar.
        window.backgroundColor = NSColor(white: 0.122, alpha: 1)
        window.title = "Vaults"
        // Hide the native title text so our custom tab strip occupies the
        // full titlebar row by itself, Termius-style.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        // No native window tabbing: terminals are embedded, never separate
        // windows that could merge into a tab group.
        window.tabbingMode = .disallowed
        // Open large (the screen's visible area) rather than a small popup that
        // the user has to double-click the titlebar to zoom.
        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        } else {
            window.center()
        }

        let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty
        // The tab strip now lives at the top of the CONTENT (just below the
        // titlebar), not as a titlebar accessory — drag-to-reorder /
        // drag-into-split only work reliably outside the titlebar's window-move
        // zone. The strip carries its own gear/bell.
        //
        // The window's content is a container with a SHARED background image at
        // the back (an NSImageView) and the SwiftUI hosting view in front. In
        // shared mode the SwiftUI content area is clear and the panes are
        // translucent, so they blend against this image — which AppKit composits
        // reliably, unlike a SwiftUI layer placed behind a Metal surface.
        let container = NSView(frame: window.contentLayoutRect)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        // IMPORTANT: use autoresizing masks, NOT Auto Layout constraints, to
        // size these subviews. Pinning a hosting view to the container with
        // required constraints lets the SwiftUI content's intrinsic size force
        // the WINDOW to grow past the screen. Autoresizing makes the subviews
        // simply follow the container without imposing a minimum window size.
        let imageView = NSImageView(frame: container.bounds)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        container.addSubview(imageView)

        let hosting = NSHostingView(rootView: VaultsRootView(
            ghostty: ghostty,
            newTabAction: { HostSearchController.shared.show() }
        ))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
        self.backgroundImageView = imageView

        super.init(window: window)
        window.delegate = self

        // Keep the backing image in sync with the shared-background settings.
        backgroundCancellable = BackgroundDisplayStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncBackgroundImage() }
        syncBackgroundImage()
    }

    /// The shared background image drawn behind the translucent panes.
    private weak var backgroundImageView: NSImageView?
    private var backgroundCancellable: AnyCancellable?

    /// Reflect `BackgroundDisplayStore` onto the backing image view.
    private func syncBackgroundImage() {
        let store = BackgroundDisplayStore.shared
        guard let imageView = backgroundImageView else { return }
        if store.useShared, let image = store.sharedImage {
            imageView.image = image
            imageView.alphaValue = store.imageVisibility
            imageView.isHidden = false
        } else {
            imageView.image = nil
            imageView.isHidden = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported.")
    }

    private var didInitialLayout = false

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Maximize to the screen the window ACTUALLY appears on. We defer one
        // runloop tick because `window.screen` isn't reliably set immediately
        // after ordering front — and on a multi-display setup the init-time
        // guess (NSScreen.main) is often the wrong, wider screen, which made the
        // window overflow.
        if !didInitialLayout {
            didInitialLayout = true
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window,
                      let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true)
            }
        } else {
            clampToScreen()
        }
        hideNativeChrome()
    }

    /// Keep the window within the visible screen area — never overflow past the
    /// screen edges (e.g. if dragged to a smaller display).
    private func clampToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    /// Defensively hide a native macOS tab bar if one ever appears (the window
    /// disallows tabbing, but the "…" the user reported looks like a stray
    /// native tab bar). Runs on a few delays since it can appear late.
    private func hideNativeChrome() {
        for delay in [0.0, 0.1, 0.3, 0.6] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window?.tabBarView?.isHidden = true
            }
        }
    }

    func hide() {
        window?.close()
    }

    // MARK: - File editor overlay

    /// The in-window file viewer/editor overlay (covers the tab bar + content).
    private var fileEditorOverlay: NSView?

    /// Present the inbuilt file viewer/editor as a full-window overlay INSIDE
    /// this window (not a separate window), so it moves/resizes with the window
    /// and can never float over other apps or detach in Mission Control.
    func presentFileEditor(model: FileViewerModel) {
        dismissFileEditor()
        guard let container = window?.contentView else { return }
        let host = NSHostingView(rootView:
            FileViewerView(model: model, onClose: { [weak self] in self?.dismissFileEditor() })
        )
        // Autoresizing (not Auto Layout) — see the note on the container above.
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: nil)
        fileEditorOverlay = host
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissFileEditor() {
        fileEditorOverlay?.removeFromSuperview()
        fileEditorOverlay = nil
    }

    /// ⌘T (and the New Tab menu item routed here) → new embedded terminal tab.
    @IBAction func newTab(_ sender: Any?) {
        VaultsTabsModel.shared.newTerminal()
    }

    // MARK: - NSWindowDelegate

    // The red button quits the app, same as ⌘Q. If any session still has a
    // running process (an agent like Claude, an SSH connection, a long-running
    // command…), we confirm first so the user doesn't kill it by accident. We
    // check here rather than relying on the app's standard quit confirmation:
    // that path only inspects `BaseTerminalController` windows, but our terminals
    // are embedded in this `HostManagerController` window, so it never sees them.
    // Always returns false — quitting is driven by NSApp.terminate below.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty

        // Nothing running → quit immediately (plain ⌘Q semantics).
        guard ghostty?.needsConfirmQuit ?? false else {
            NSApp.terminate(nil)
            return false
        }

        // Something is running → confirm before terminating. `present` defers a
        // runloop turn so the modal is responsive from this delegate callback.
        SarvAlert.present(
            title: "Quit Sarv Terminal?",
            message: "A terminal session still has a running process (e.g. an agent or SSH connection). If you quit, it will be terminated.",
            buttons: [
                .init("Quit", isDestructive: true),
                .init("Cancel", isCancel: true),
            ]
        ) { result in
            if result.buttonIndex == 0 { NSApp.terminate(nil) }
        }
        return false
    }
}

/// A window that refuses to become non-opaque. Ghostty flips `isOpaque` to
/// false whenever a surface is translucent (so transparency blends with the
/// desktop), but in the embedded single-window layout we want translucent panes
/// to blend against our own window-level shared image instead — which requires
/// the window to stay opaque. Forcing the getter guarantees that regardless of
/// who tries to set it.
final class OpaqueWindow: NSWindow {
    override var isOpaque: Bool {
        get { true }
        set { /* ignore attempts to make us transparent */ }
    }
}
