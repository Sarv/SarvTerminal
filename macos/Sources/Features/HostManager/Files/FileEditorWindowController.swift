import AppKit
import SwiftUI

/// Opens the inbuilt file viewer/editor as a full-window overlay INSIDE the main
/// window (see `HostManagerController.presentFileEditor`) — the editor is part of
/// the window, so it moves/resizes with it and never floats over other apps or
/// detaches in Mission Control. Kept as a thin façade so existing call sites
/// (`FileEditorWindowController.shared.open(...)`) don't change. Dismissed by the
/// viewer's own ✕ button.
@MainActor
final class FileEditorWindowController {
    static let shared = FileEditorWindowController()

    private init() {}

    /// Open a local file path in the inbuilt editor.
    func open(path: String) {
        let item = FileItem(
            name: (path as NSString).lastPathComponent,
            path: path, isDirectory: false, isSymlink: false,
            size: 0, modified: nil, permissions: nil
        )
        open(model: FileViewerModel(item: item, backend: LocalFileBackend()))
    }

    /// Open an already-configured viewer model (e.g. a remote file from the SFTP
    /// browser) in the full-window overlay.
    func open(model: FileViewerModel) {
        HostManagerController.shared.presentFileEditor(model: model)
    }
}
