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
    /// Trailing edge (points from the leading edge) of the close-button hit
    /// region.
    let closeHitWidth: CGFloat
    /// Leading edge (points) of the close-button hit region — skips the dead
    /// padding before the visible ✕ so a select-click on the far-left edge
    /// doesn't close the tab.
    let closeHitLeadingInset: CGFloat
    let onActivate: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    /// Mouse is over the leading close-button region specifically.
    let onCloseHoverChanged: (Bool) -> Void
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
        view.closeHitLeadingInset = closeHitLeadingInset
        view.onActivate = onActivate
        view.onClose = onClose
        view.onHoverChanged = onHoverChanged
        view.onCloseHoverChanged = onCloseHoverChanged
        view.menuItems = menuItems
    }
}

final class TabChipInteractionView: NSView, NSDraggingSource {
    var tabID: UUID?
    var closeHitWidth: CGFloat = 0
    var closeHitLeadingInset: CGFloat = 0
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseHoverChanged: ((Bool) -> Void)?
    var menuItems: [TabChipMenuItem] = []

    private var isTracking = false
    /// Set synchronously the moment `mouseDragged` begins a drag session, and
    /// cleared on the next `mouseDown`. `isTracking` only flips true in the
    /// async `willBeginAt` callback, so a fast drag can reach `mouseUp` before
    /// it's set — this flag guarantees a drag is never mistaken for a click
    /// (which would close/select the tab out from under the reorder).
    private var didBeginDrag = false
    private var isHovering = false
    private var isCloseHovering = false
    private var mouseDownLocation: NSPoint?
    private var menuActions: [() -> Void] = []
    /// Coalesces the geometry-driven hover reconcile to one call per runloop tick.
    private var reconcileScheduled = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// True when `point` (view coords) is on the visible close button: inside the
    /// chip and within the leading close band. The single source of truth for
    /// the cursor, the close-hover highlight, and the close-on-click decision.
    private func isInCloseRegion(_ point: NSPoint) -> Bool {
        bounds.contains(point) && point.x >= closeHitLeadingInset && point.x <= closeHitWidth
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil))
        scheduleHoverReconcile()
    }

    // A chip moving under a stationary cursor (the strip auto-scrolls on ⌘-number,
    // a neighbor closes, a new tab is added) posts no mouse event, so the
    // enter/exit-driven hover state would go stale and strand the close ✕ on the
    // wrong chip. Re-sync against the real pointer on every geometry change.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleHoverReconcile()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleHoverReconcile()
    }

    private func scheduleHoverReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        // Async so we never mutate SwiftUI @State from inside a layout pass, and
        // so we read the pointer after the geometry settles.
        DispatchQueue.main.async { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcileHover()
        }
    }

    /// Force hover state to match where the pointer actually is right now.
    private func reconcileHover() {
        guard !isTracking else { return }   // a drag owns the cursor
        guard let window, window.isVisible else {
            setHover(false)
            setCloseHover(false)
            return
        }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(local)
        setHover(inside)
        setCloseHover(inside && isInCloseRegion(local))
    }

    override func resetCursorRects() {
        if isTracking {
            addCursorRect(bounds, cursor: .closedHand)
            return
        }
        // Normal arrow over the close button; grab hand over the rest (including
        // the dead padding to the left of the button, which selects on click).
        let closeMinX = min(closeHitLeadingInset, bounds.width)
        let closeMaxX = min(closeHitWidth, bounds.width)
        let closeRect = NSRect(x: closeMinX, y: 0, width: max(0, closeMaxX - closeMinX), height: bounds.height)
        if !closeRect.isEmpty { addCursorRect(closeRect, cursor: .arrow) }
        if closeMinX > 0 {
            addCursorRect(NSRect(x: 0, y: 0, width: closeMinX, height: bounds.height), cursor: .openHand)
        }
        let trailing = NSRect(x: closeRect.maxX, y: 0,
                              width: max(0, bounds.width - closeRect.maxX), height: bounds.height)
        if !trailing.isEmpty { addCursorRect(trailing, cursor: .openHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
        updateCloseHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false)
        setCloseHover(false)
    }

    override func mouseMoved(with event: NSEvent) { updateCloseHover(with: event) }

    private func updateCloseHover(with event: NSEvent) {
        setCloseHover(isInCloseRegion(convert(event.locationInWindow, from: nil)))
    }

    private func setHover(_ value: Bool) {
        guard value != isHovering else { return }
        isHovering = value
        onHoverChanged?(value)
    }

    private func setCloseHover(_ value: Bool) {
        guard value != isCloseHovering else { return }
        isCloseHovering = value
        onCloseHoverChanged?(value)
    }

    // Don't call super: we decide click-vs-drag ourselves, and consuming the
    // event keeps the enclosing scroll view / window from stealing the press.
    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isTracking, !didBeginDrag, let tabID, let start = mouseDownLocation else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        // Mark the drag as started synchronously, before the (async) tracking
        // callbacks fire, so a concurrent `mouseUp` can't treat it as a click.
        didBeginDrag = true

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
        guard !isTracking, !didBeginDrag else { return }   // a drag happened; not a click
        let up = convert(event.locationInWindow, from: nil)
        // A release that drifted off the chip entirely (implicit mouse capture
        // still routes it here) is neither a close nor a select.
        guard bounds.contains(up) else { return }
        // Close only when BOTH the press and the release land on the close
        // button; otherwise select. Requiring the press to start there too keeps
        // a click meant to switch tabs — which may graze the leading edge — from
        // closing the tab.
        let down = mouseDownLocation.map { convert($0, from: nil) }
        if let down, isInCloseRegion(down), isInCloseRegion(up) {
            onClose?()
        } else {
            onActivate?()
        }
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
