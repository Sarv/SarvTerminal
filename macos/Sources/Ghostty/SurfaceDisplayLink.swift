import AppKit
import QuartzCore
import GhosttyKit

extension Ghostty {
    /// Paces one surface's frames to the refresh rate of the display it is on.
    ///
    /// macOS 14 added `NSView.displayLink(target:selector:)`, which hands back a
    /// `CADisplayLink` that follows whichever screen the view is actually on and
    /// fires on the main run loop. That is meaningfully safer than the
    /// CVDisplayLink libghostty falls back to on macOS 13, which has its own IO
    /// thread: CoreVideo stops every live link from the main thread whenever the
    /// display configuration changes, and waits on each of those IO threads with
    /// no timeout, so getting in the way of it hangs the whole app until it is
    /// killed. AppKit's link has no IO thread, so none of that applies, and it
    /// re-targets itself when the window moves between screens so we never have
    /// to tell it which display we are on.
    ///
    /// Ticks request a frame rather than drawing one: each wakes the surface's
    /// render thread and returns immediately. `ghostty_surface_draw_now` is
    /// documented never to block, and it has to stay that way -- a display link
    /// callback that blocks is the whole problem we are avoiding.
    @available(macOS 14.0, *)
    class SurfaceDisplayLink: NSObject {
        /// The view whose surface we drive.
        ///
        /// Weak on purpose. `CADisplayLink` retains its target and the run loop
        /// retains the link, so a strong reference here would keep a closed
        /// surface alive indefinitely with a live link still ticking at it.
        private weak var view: SurfaceView?

        private var link: CADisplayLink?

        /// The last value we reported to libghostty, or nil if we never have.
        ///
        /// libghostty needs to know whether anything is pacing frames, because
        /// when nothing is it has to go back to drawing whenever content
        /// changes. Nil rather than false so the first sync always reports,
        /// which is also what hands vsync over to us in the first place.
        private var reported: Bool?

        init(view: SurfaceView) {
            self.view = view
            super.init()
        }

        /// Start, stop or drop the link to match the surface's current state.
        ///
        /// Cheap to call redundantly, so callers don't have to work out whether
        /// anything actually changed. Call it whenever focus, window visibility
        /// or window membership changes.
        func sync() {
            guard let view, let surface = view.surface else { return }

            // `window-vsync` off means the user asked for frames as soon as
            // content changes rather than paced to the display, so we must not
            // tick at all -- every tick would draw a frame whether or not
            // anything changed. Past that, the same condition libghostty
            // applies to its own display link: there is nothing to pace for a
            // surface nobody can see, or for an unfocused split whose content
            // only changes when something happens to it.
            let wanted = view.derivedConfig.windowVsync
                && view.window != nil
                && view.isWindowVisible
                && view.focused

            if view.window == nil {
                // No window means no screen to pace against, and the view may
                // be on its way out of the hierarchy. Drop the link instead of
                // keeping a paused one around; we build a new one if the view
                // comes back, which it does on every split rebuild.
                invalidate()
            } else if wanted, link == nil {
                // Created lazily, and only while the view is in a window,
                // because that is what gives AppKit a screen to pace against.
                let created = view.displayLink(target: self, selector: #selector(tick))
                created.add(to: .main, forMode: .common)
                link = created
            }

            link?.isPaused = !wanted

            if reported != wanted {
                reported = wanted
                ghostty_surface_set_vsync_external(surface, wanted)
            }
        }

        /// Stop ticking and release the link.
        ///
        /// Must be called before the view goes away. The run loop holds the link
        /// until it is invalidated and the link holds us, so nothing else in the
        /// chain breaks on its own.
        func invalidate() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ sender: CADisplayLink) {
            guard let surface = view?.surface else {
                // The view or its surface went away without anyone invalidating
                // us. There is nothing left to draw for, so stop waking the
                // main thread sixty-plus times a second to find that out again.
                invalidate()
                return
            }

            ghostty_surface_draw_now(surface)
        }
    }
}
