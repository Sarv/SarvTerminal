import SwiftUI
import AppKit

/// A reusable keyboard-navigable list for palettes and pickers.
///
/// Renders `items` with a highlighted `selection`, and — while its window is the
/// key window — captures the navigation keys so they behave identically
/// everywhere AND never leak to whatever sits behind the palette (e.g. a running
/// terminal session, where a stray Esc would interrupt the foreground program):
///
///   - ↑ / ↓        move the selection (and auto-scroll it into view)
///   - Return/Enter activate the selected item
///   - Esc          cancel (`onCancel`)
///
/// Every OTHER keystroke passes through untouched, so a search field hosted
/// alongside this list keeps receiving typed characters normally. Hover and
/// click also select / activate.
///
/// This is the single place list keyboard behavior lives — reuse it for any
/// palette/picker instead of re-implementing arrow handling per view.
struct KeyNavigableList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// Index into `items`, or nil when nothing is highlighted.
    @Binding var selection: Int?
    var onActivate: (Item) -> Void
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var row: (_ item: Item, _ isSelected: Bool) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        // NB: no explicit `.id(idx)` here — a position-based id
                        // inside a ForEach already keyed by `\.element.id`
                        // conflicts, making the lazy stack reuse stale rows when
                        // the items change (e.g. filtered search showed the old,
                        // unfiltered rows). Scroll targets the item's own id.
                        row(item, idx == selection)
                            .contentShape(Rectangle())
                            .onHover { if $0 { selection = idx } }
                            .onTapGesture { onActivate(item) }
                    }
                }
                .padding(8)
            }
            .background(KeyNavCapture(
                onMove: { move($0) },
                onActivate: {
                    if let s = selection, items.indices.contains(s) { onActivate(items[s]) }
                },
                onCancel: { onCancel?() }))
            .onChange(of: selection) { newValue in
                // Keep the selection visible with the MINIMUM scroll (anchor nil
                // is a no-op when it's already on screen) and no animation — so
                // arrow-stepping never re-centers or jumps the list; the list
                // only moves when the highlight would otherwise go off screen.
                guard let newValue, items.indices.contains(newValue) else { return }
                proxy.scrollTo(items[newValue].id, anchor: nil)
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { selection = nil; return }
        switch selection {
        case nil:
            // From the search field (nothing selected): ↓ enters the list at the
            // top; ↑ stays in the field (no wrap to the bottom).
            guard delta > 0 else { return }
            selection = 0
        case let current?:
            let next = current + delta
            // Moving up off the top deselects (nil) so the host view can hand
            // focus back to the search field; moving down clamps at the end.
            selection = next < 0 ? nil : min(items.count - 1, next)
        }
    }
}

/// Invisible AppKit bridge that owns the navigation keys while its window is
/// key. A LOCAL keyDown monitor runs before the responder chain, so ↑/↓/Enter/
/// Esc are handled (and swallowed) here while all other keys fall through to the
/// focused text field. The monitor is anchored to the view's window lifetime so
/// it's installed/removed exactly when the list is on screen.
private struct KeyNavCapture: NSViewRepresentable {
    var onMove: (Int) -> Void
    var onActivate: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.apply(onMove: onMove, onActivate: onActivate, onCancel: onCancel)
        return v
    }

    func updateNSView(_ v: CaptureView, context: Context) {
        v.apply(onMove: onMove, onActivate: onActivate, onCancel: onCancel)
    }

    static func dismantleNSView(_ v: CaptureView, coordinator: ()) {
        v.removeMonitor()
    }

    final class CaptureView: NSView {
        private var onMove: ((Int) -> Void)?
        private var onActivate: (() -> Void)?
        private var onCancel: (() -> Void)?
        private var monitor: Any?

        func apply(onMove: @escaping (Int) -> Void,
                   onActivate: @escaping () -> Void,
                   onCancel: @escaping () -> Void) {
            self.onMove = onMove
            self.onActivate = onActivate
            self.onCancel = onCancel
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { installMonitor() } else { removeMonitor() }
        }

        deinit { removeMonitor() }

        private func installMonitor() {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Only own the keyboard while our palette is actually the key
                // window; otherwise pass everything through untouched.
                guard let self, self.window?.isKeyWindow == true else { return event }
                switch event.keyCode {
                case 125: self.onMove?(+1); return nil       // ↓
                case 126: self.onMove?(-1); return nil       // ↑
                case 36, 76: self.onActivate?(); return nil  // Return / Keypad Enter
                case 53: self.onCancel?(); return nil        // Esc
                default: return event                        // typing → search field
                }
            }
        }

        func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}
