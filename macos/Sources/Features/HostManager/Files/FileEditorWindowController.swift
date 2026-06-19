import AppKit
import SwiftUI

/// Hosts the inbuilt file viewer/editor in a chromeless, full-cover window (no
/// traffic lights / resize) — used to "edit config file" the same way the
/// SFTP viewer works, instead of an external app or a popup. Dismissed by the
/// viewer's own ✕ button.
final class FileEditorWindowController: NSWindowController {
    static let shared = FileEditorWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Open a local file path in the inbuilt editor.
    func open(path: String) {
        guard let window else { return }
        let item = FileItem(
            name: (path as NSString).lastPathComponent,
            path: path, isDirectory: false, isSymlink: false,
            size: 0, modified: nil, permissions: nil
        )
        let model = FileViewerModel(item: item, backend: LocalFileBackend())
        window.contentView = NSHostingView(rootView:
            FileViewerView(model: model, onClose: { [weak self] in self?.window?.close() })
        )
        if let key = NSApp.keyWindow ?? HostManagerController.shared.window {
            window.setFrame(key.frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
