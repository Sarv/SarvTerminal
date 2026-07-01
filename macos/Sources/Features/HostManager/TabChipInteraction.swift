import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One right-click menu entry for a tab chip.
struct TabChipMenuItem {
    let title: String
    let action: () -> Void
    /// Insert a separator ABOVE this item.
    var separatorBefore: Bool = false
}

/// AppKit-backed interaction layer for a tab chip: tap-to-select, press-drag to
/// reorder / split (an `NSDraggingSession` carrying `vaultsTabID`), hover
/// tracking, the grab-hand → closed-hand cursor, and the right-click menu.
///
/// SwiftUI's `.onDrag` lets macOS control the cursor during a drag, so — exactly
/// like the split-pane drag handle (`Ghostty.SurfaceDragSource`) — we run the
/// drag session ourselves to get the open-hand → closed-hand "grab" affordance.
/// The view sits ON TOP of the (non-interactive) SwiftUI chip visual and decides
/// close-vs-select by click location, so there's no AppKit/SwiftUI hit-test race.
struct TabChipInteraction: NSViewRepresentable {
    let tabID: UUID
    /// Leading width (points) that counts as the close-button hit region.
    let closeHitWidth: CGFloat
    let onActivate: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    let menuItems: [TabChipMenuItem]

    func makeNSView(context: Context) -> TabChipInteractionView {
        let view = TabChipInteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: TabChipInteractionView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TabChipInteractionView) {
        view.tabID = tabID
        view.closeHitWidth = closeHitWidth
        view.onActivate = onActivate
        view.onClose = onClose
        view.onHoverChanged = onHoverChanged
        view.menuItems = menuItems
    }
}

final class TabChipInteractionView: NSView, NSDraggingSource {
    var tabID: UUID?
    var closeHitWidth: CGFloat = 0
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var menuItems: [TabChipMenuItem] = []

    private var isTracking = false
    private var mouseDownLocation: NSPoint?
    private var menuActions: [() -> Void] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    // Don't call super: we decide click-vs-drag ourselves, and consuming the
    // event keeps the enclosing scroll view / window from stealing the press.
    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isTracking, let tabID, let start = mouseDownLocation else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }

        let item = NSPasteboardItem()
        item.setData(
            Data(tabID.uuidString.utf8),
            forType: NSPasteboard.PasteboardType(UTType.vaultsTabID.identifier))
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        if let image = snapshot() {
            let mouse = convert(event.locationInWindow, from: nil)
            dragItem.setDraggingFrame(
                NSRect(x: mouse.x - image.size.width / 2,
                       y: mouse.y - image.size.height / 2,
                       width: image.size.width, height: image.size.height),
                contents: image)
        } else {
            dragItem.setDraggingFrame(bounds, contents: nil)
        }
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !isTracking else { return }   // a drag happened; not a click
        // Click in the leading close-button region closes; anywhere else selects.
        let p = convert(event.locationInWindow, from: nil)
        if p.x <= closeHitWidth { onClose?() } else { onActivate?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !menuItems.isEmpty else { return super.rightMouseDown(with: event) }
        let menu = NSMenu()
        menuActions = []
        for entry in menuItems {
            if entry.separatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menuActions.count
            menuActions.append(entry.action)
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        menuActions[sender.tag]()
    }

    /// Snapshot the rendered chip from the window backing (this view is
    /// transparent, so we capture its frame region from the content view) for a
    /// drag preview that looks like the chip.
    private func snapshot() -> NSImage? {
        guard let content = window?.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard rect.width > 1, rect.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isTracking = true
        window?.invalidateCursorRects(for: self)
        // Mark which tab is in flight so the split drop zones can hide over its
        // own surfaces (a tab can't be split into itself).
        VaultsTabsModel.shared.draggingTabID = tabID
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isTracking = false
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
        VaultsTabsModel.shared.draggingTabID = nil
    }
}
