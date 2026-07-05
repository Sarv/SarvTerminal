import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit-native drop target overlaid on a split pane.
///
/// Why not SwiftUI `.onDrop`: pane drags are AppKit `NSDraggingSession`s
/// (started by `SurfaceDragSource`), and SwiftUI's drop bridge over the Metal
/// surface view delivers the hover callbacks but silently drops
/// `performDrop` — the session ends `.move` with no perform (verified via
/// /tmp logging, July 2026). Accepting the drag at the AppKit layer — the
/// same layer the session runs on — is reliable.
struct PaneDropTarget: NSViewRepresentable {
    /// What was dropped on the pane.
    enum Payload {
        case surface(UUID)   // a pane dragged by its header
        case tab(UUID)       // a tab chip dragged from the strip
    }

    /// When false the view refuses drags (e.g. while THIS pane is the one
    /// being dragged, or while it shows the split chooser).
    var enabled: Bool = true
    /// Live drop-zone updates while a drag hovers (nil = left / ended).
    let onZone: (TerminalSplitDropZone?) -> Void
    /// A payload was dropped in the given zone.
    let onPerform: (Payload, TerminalSplitDropZone) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onZone = onZone
        view.onPerform = onPerform
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onZone = onZone
        view.onPerform = onPerform
        view.enabled = enabled
    }

    final class DropView: NSView {
        static let surfaceType = NSPasteboard.PasteboardType(UTType.ghosttySurfaceId.identifier)
        static let tabType = NSPasteboard.PasteboardType(UTType.vaultsTabID.identifier)

        var onZone: ((TerminalSplitDropZone?) -> Void)?
        var onPerform: ((PaneDropTarget.Payload, TerminalSplitDropZone) -> Void)?
        var enabled = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([Self.surfaceType, Self.tabType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        /// Zone math expects top-left-origin coordinates (SwiftUI-style).
        override var isFlipped: Bool { true }

        /// Transparent to normal mouse events — only drag sessions land here
        /// (AppKit's drag-destination search ignores hitTest).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func zone(for sender: NSDraggingInfo) -> TerminalSplitDropZone {
            let p = convert(sender.draggingLocation, from: nil)
            return .calculate(at: p, in: bounds.size)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard enabled else { return [] }
            onZone?(zone(for: sender))
            return .move
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard enabled else { return [] }
            onZone?(zone(for: sender))
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onZone?(nil)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onZone?(nil)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard enabled else { return false }
            let zone = zone(for: sender)
            onZone?(nil)
            let pasteboard = sender.draggingPasteboard

            // Surface payload: 16 raw UUID bytes (SurfaceView's Transferable).
            if let data = pasteboard.data(forType: Self.surfaceType), data.count == 16 {
                let uuid = data.withUnsafeBytes { $0.load(as: UUID.self) }
                onPerform?(.surface(uuid), zone)
                return true
            }
            // Tab payload: UUID string (TabChipInteraction).
            if let data = pasteboard.data(forType: Self.tabType),
               let string = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: string) {
                onPerform?(.tab(id), zone)
                return true
            }
            return false
        }
    }
}
