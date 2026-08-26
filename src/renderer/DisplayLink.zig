//! A hang-proof, shared CVDisplayLink.
//!
//! CVDisplayLink cannot safely be driven from a background thread. CoreVideo
//! installs its own display reconfiguration handler, and whenever the display
//! configuration changes (monitor plugged or unplugged, display sleep/wake,
//! resolution or refresh rate change, a window moving between screens) that
//! handler runs on the main thread and calls `CVDisplayLinkStop` on *every*
//! live link, holding a global CoreVideo lock while it waits on each link's IO
//! thread. The wait has no timeout.
//!
//! If we call into the same link from a render thread at that moment we can
//! invert the lock order, and the main thread parks inside
//! `CVDisplayLinkStop` forever: the entire app hangs, the wait never expires,
//! and the process has to be killed. Apple deprecated CVDisplayLink in macOS
//! 15 in favor of `NSView.displayLink(target:selector:)` largely because of
//! this class of problem.
//!
//! To make that impossible, this file guarantees:
//!
//!   1. Every CoreVideo call runs on the main thread, posted with
//!      `dispatch_async`. All of our access is therefore serialized against
//!      CoreVideo's own reconfiguration handler and there is never a second
//!      thread inside a link. Ops are never run inline even when we already
//!      happen to be on the main thread, because FIFO main queue ordering is
//!      what keeps teardown safely after everything we already queued.
//!
//!   2. `isRunning` never enters CoreVideo. The main thread caches the link's
//!      real state into an atomic after every op, so the per-frame vsync
//!      check on the render thread is an atomic load rather than a CoreVideo
//!      lock acquisition. Previously this was called on every draw, from
//!      every render thread, which is what made the race so easy to lose.
//!
//!   3. Requests that wouldn't change anything are dropped before they reach
//!      CoreVideo, so the burst of focus and visibility changes that arrives
//!      during a display reconfiguration costs nothing.
//!
//!   4. The requested state is re-asserted after a display reconfiguration,
//!      because CoreVideo stops links behind our back when the configuration
//!      changes. Without this, caching in (2) would leave a surface believing
//!      it is vsync-driven when nothing is driving it.
//!
//!   5. There is exactly **one** CVDisplayLink per physical display, shared by
//!      every surface on it, rather than one per surface. A window with a
//!      dozen splits used to mean a dozen links against the same two screens:
//!      a dozen IO threads all ticking at the same refresh rate, and a dozen
//!      links for CoreVideo's reconfiguration handler to stop one at a time
//!      while holding its global lock. Sharing collapses that to one link per
//!      screen, which is both what the hardware actually is and the smallest
//!      window we can give the bug in (1).
//!
//! The fan-out from a shared link to its surfaces happens on CoreVideo's IO
//! thread, so it is lock-free by construction. See `Display.slots` and
//! `displayCallback` -- a mutex there would reintroduce exactly the deadlock
//! this file exists to prevent.

/// One surface's subscription to the shared link for the display it is on.
///
/// This is the handle the renderer holds. It does not own a CVDisplayLink;
/// `Display` does.
const Subscription = @This();

const std = @import("std");
const objc = @import("objc");
const macos = @import("macos");
const global = @import("../global.zig");
const xev = global.xev;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.display_link);

/// The display ID value meaning "we haven't been told which display yet".
///
/// Surfaces start out here, because a render thread comes up before anyone
/// tells it which screen its window is on. It behaves like any other display
/// except that we never bind its link to a specific screen, leaving it on
/// whatever `createWithActiveCGDisplays` chose.
const no_display: u32 = macos.graphics.display_config.null_display;

/// How many surfaces one display's link can drive.
///
/// The fan-out array is fixed size on purpose: it means the IO thread needs no
/// lock, no allocation and no reclamation scheme to read it, which is what
/// keeps that thread unable to block. This is a per-*screen* surface count, so
/// it only has to be larger than the number of splits and tabs a human can
/// have visible on one monitor at once.
const max_surfaces_per_display = 64;

/// Allocator that owns this subscription.
alloc: Allocator,

/// The async to notify from the shared link's IO thread on every vsync.
///
/// Immutable after creation, so the IO thread may read it without
/// synchronization for as long as we are reachable from a slot.
draw_now: *xev.Async,

/// Whether frames are actually being delivered to us, cached so that
/// `isRunning` never has to call into CoreVideo. Written on the main thread
/// after every op, read from any thread.
running: std.atomic.Value(bool) = .init(false),

/// Whether we want frames at all. Written by the owning render thread; read on
/// the main thread when applying, and on the IO thread to decide whether to
/// notify us, so it's atomic.
wants_running: std.atomic.Value(bool) = .init(false),

/// The display we want frames from, or `no_display` if we haven't been told
/// yet. Same threading as `wants_running`.
wants_display: std.atomic.Value(u32) = .init(no_display),

/// The shared link we're attached to, and our index in its fan-out array.
/// Both null or both set.
///
/// MAIN THREAD ONLY.
display: ?*Display = null,
slot: ?u32 = null,

/// Whether we're in `live` yet. MAIN THREAD ONLY.
registered: bool = false,

/// Every live subscription, so a display reconfiguration can re-assert all of
/// them, and every shared link we've created.
///
/// MAIN THREAD ONLY: every mutation happens inside a block on the main queue,
/// so these need no lock. A lock here would be actively dangerous -- see the
/// note in `displayCallback` about never blocking the IO thread.
var live: std.ArrayList(*Subscription) = .empty;
var displays: std.ArrayList(*Display) = .empty;

/// Whether we've installed our process-wide reconfiguration callback.
/// MAIN THREAD ONLY.
var reconfiguration_registered: bool = false;

/// Create a subscription for a render thread's `draw_now` async.
///
/// No CoreVideo object is created or joined yet: that happens lazily on the
/// main thread the first time frames are actually wanted, so a surface that
/// never becomes visible and focused never pays for one.
pub fn create(alloc: Allocator, draw_now: *xev.Async) Allocator.Error!*Subscription {
    const self = try alloc.create(Subscription);
    self.* = .{ .alloc = alloc, .draw_now = draw_now };
    return self;
}

/// Detach from the shared link and free.
///
/// The work is posted to the main queue rather than done inline, which both
/// keeps us off CoreVideo from this thread and guarantees teardown runs after
/// any op we already queued. Do not touch the subscription after calling this.
pub fn deinit(self: *Subscription) void {
    self.post(.destroy);
}

/// Take frames from the display the surface is on.
pub fn setDisplay(self: *Subscription, display_id: u32) void {
    if (self.wants_display.swap(display_id, .monotonic) == display_id) return;
    self.post(.apply);
}

/// Request that frames start or stop being delivered.
pub fn setRunning(self: *Subscription, running: bool) void {
    if (self.wants_running.swap(running, .monotonic) == running) return;
    self.post(.apply);
}

/// True if CoreVideo is currently driving frames for us, meaning the render
/// thread should not be drawing on its own.
///
/// This is a plain atomic load. It is called on every draw, so it must never
/// reach into CoreVideo.
pub fn isRunning(self: *const Subscription) bool {
    return self.running.load(.acquire);
}

/// Explicit tag type: this crosses into an objc block capture, which must be
/// an extern-compatible struct.
const Op = enum(u8) {
    /// Bring CoreVideo in line with the requested state, joining or leaving a
    /// shared link as needed. Idempotent, so it doubles as the retry for a
    /// create that failed.
    apply,

    /// Detach and free.
    destroy,

    /// A display reconfiguration has finished: re-assert everything and drop
    /// links for displays nobody is on any more.
    ///
    /// Global work that happens to be posted through a subscription because a
    /// block needs something to capture. Its carrier may already have been
    /// freed by a `destroy` queued ahead of it, so the carrier must never be
    /// dereferenced for this op.
    settled,
};

const OpBlock = objc.Block(struct {
    self: *Subscription,
    op: Op,
}, .{}, void);

/// Queue an op onto the main queue.
///
/// This never runs the op inline, even when we're already on the main thread.
/// Running inline would break FIFO ordering against ops other threads have
/// already queued, and `destroy` depends on that ordering to avoid freeing a
/// subscription out from under a pending `apply`.
fn post(self: *Subscription, op: Op) void {
    // The block is copied by dispatch_async and released by the objc runtime
    // once it has run, so a stack block is fine here.
    var block = OpBlock.init(.{ .self = self, .op = op }, &runOp);
    macos.dispatch.dispatch_async(
        @ptrCast(macos.dispatch.queue.getMain()),
        @ptrCast(&block),
    );
}

fn runOp(block: *const OpBlock.Context) callconv(.c) void {
    switch (block.op) {
        .apply => block.self.applyOnMain(),
        .destroy => block.self.destroyOnMain(),

        // Deliberately does not touch `self`, which may already be freed:
        // see the note on `Op.settled`.
        .settled => settledOnMain(),
    }
}

/// Join the right shared link and make CoreVideo match what we want.
/// MAIN THREAD ONLY.
fn applyOnMain(self: *Subscription) void {
    if (!self.registered) self.registerOnMain();

    const wants_display = self.wants_display.load(.monotonic);

    // Move to another display's link if the window has been dragged between
    // screens, or if we've only just been told which screen we're on.
    const left: ?*Display = left: {
        const current = self.display orelse break :left null;
        if (current.id == wants_display) break :left null;
        self.detachOnMain();
        break :left current;
    };

    if (self.display == null) self.attachOnMain(wants_display);

    // The display we left may have nothing to drive any more. Stop it, and if
    // we were its last surface release its link now rather than leaving it for
    // CoreVideo to keep stopping on every future reconfiguration. This has to
    // happen after we've joined the new display, so that pruning can't destroy
    // a display we are about to attach to and immediately recreate.
    if (left) |display| {
        display.applyOnMain();
        pruneDisplaysOnMain();
    }

    const display = self.display orelse {
        // No shared link to join, either because we couldn't allocate one or
        // because this display already has more surfaces than we fan out to.
        // Rendering continues without vsync and the next apply retries.
        self.running.store(false, .release);
        return;
    };

    display.applyOnMain();
}

/// Take a slot in a display's fan-out array, creating the shared link's owner
/// if we're the first surface on that display. MAIN THREAD ONLY.
///
/// We attach whether or not we currently want frames: attaching is free, an
/// attached surface that doesn't want frames is skipped by the IO thread, and
/// keeping the attachment across focus changes avoids churning CoreVideo
/// every time the user switches windows.
fn attachOnMain(self: *Subscription, display_id: u32) void {
    std.debug.assert(self.display == null);

    const display = displayForOnMain(display_id) orelse return;
    const slot = display.claimSlotOnMain(self) orelse {
        log.warn(
            "too many surfaces on one display for vsync; " ++
                "using fallback rendering display={} max={}",
            .{ display_id, max_surfaces_per_display },
        );
        return;
    };

    self.display = display;
    self.slot = slot;
}

/// Give up our slot. MAIN THREAD ONLY.
///
/// This does not stop the shared link. The IO thread may already have loaded
/// our pointer out of the slot, but we stay allocated, so the worst case is
/// one spurious wakeup of a still-valid async. Freeing is the case that has to
/// be ordered against the IO thread -- see `destroyOnMain`.
fn detachOnMain(self: *Subscription) void {
    const display = self.display orelse return;

    display.slots[self.slot.?].store(null, .release);
    self.display = null;
    self.slot = null;
    self.running.store(false, .release);
}

/// MAIN THREAD ONLY. Frees the subscription; nothing may touch it afterwards.
fn destroyOnMain(self: *Subscription) void {
    if (self.display) |display| {
        // The IO thread may already have loaded our pointer out of its slot,
        // so clearing the slot is not enough to make freeing safe. Stopping
        // the link is: `CVDisplayLinkStop` waits for an in-flight callback to
        // return, which it always can because our callback never blocks, and
        // after it returns the callback provably is not running. This is safe
        // here only because we are on the main thread, where nothing else can
        // be inside the link.
        if (display.link) |link| link.stop() catch {};

        self.detachOnMain();

        // Restart for whatever surfaces are left on this display.
        display.applyOnMain();
    }

    if (self.registered) {
        for (live.items, 0..) |item, i| {
            if (item != self) continue;
            _ = live.swapRemove(i);
            break;
        }
    }

    self.alloc.destroy(self);
    pruneDisplaysOnMain();
}

/// MAIN THREAD ONLY.
fn registerOnMain(self: *Subscription) void {
    live.append(global.alloc(), self) catch |err| {
        // Not fatal. We lose the post-reconfiguration re-assert for this
        // surface, which degrades to change-driven rendering rather than
        // hanging, and we'll try again on the next apply.
        log.warn("error tracking display link err={}", .{err});
        return;
    };
    self.registered = true;

    if (reconfiguration_registered) return;
    macos.graphics.display_config.registerReconfigurationCallback(
        &reconfigurationCallback,
        null,
    ) catch |err| {
        log.warn(
            "error registering display reconfiguration callback err={}",
            .{err},
        );
        return;
    };
    reconfiguration_registered = true;
}

/// The owner of the shared link for `display_id`, created if this is the first
/// surface we've seen on it. MAIN THREAD ONLY.
fn displayForOnMain(display_id: u32) ?*Display {
    for (displays.items) |display| {
        if (display.id == display_id) return display;
    }

    const alloc = global.alloc();
    const display = alloc.create(Display) catch |err| {
        log.warn("error allocating display link owner err={}", .{err});
        return null;
    };
    display.* = .{ .id = display_id };

    displays.append(alloc, display) catch |err| {
        log.warn("error tracking display link owner err={}", .{err});
        alloc.destroy(display);
        return null;
    };

    return display;
}

/// Release the links of displays no surface is on any more, so unplugging a
/// monitor doesn't leave its link behind for CoreVideo to keep stopping on
/// every future reconfiguration. MAIN THREAD ONLY.
fn pruneDisplaysOnMain() void {
    var i: usize = 0;
    while (i < displays.items.len) {
        const display = displays.items[i];
        if (display.hasSurfacesOnMain()) {
            i += 1;
            continue;
        }

        display.destroyOnMain();
        _ = displays.swapRemove(i);
    }
}

/// Re-assert every subscription after a display reconfiguration.
/// MAIN THREAD ONLY.
fn settledOnMain() void {
    for (live.items) |item| item.applyOnMain();
    pruneDisplaysOnMain();
}

/// Called by CoreGraphics on the main thread when the display configuration
/// changes.
///
/// CoreVideo has its own handler for the same event that stops every live
/// link, so once the dust settles our cached state is stale and links we
/// wanted running have been stopped. We re-assert.
///
/// It is *not* safe to touch a display link from inside this callback -- that
/// is exactly the deadlock this file exists to avoid -- so we only post work.
/// The main queue runs it after the reconfiguration has finished.
fn reconfigurationCallback(
    display: macos.graphics.display_config.DirectDisplayID,
    flags: macos.graphics.display_config.ChangeSummaryFlags,
    _: ?*anyopaque,
) callconv(.c) void {
    // These two logs bracket the window in which a CoreVideo hang would
    // occur. If a "begin" ever appears with no matching "settled", the main
    // thread wedged inside the reconfiguration and the log says so without
    // anyone having to catch the process live with `sample`.
    if (macos.graphics.display_config.isBeginConfiguration(flags)) {
        log.info(
            "display reconfiguration begin display={} links={} surfaces={}",
            .{ display, displays.items.len, live.items.len },
        );
        return;
    }

    log.info(
        "display reconfiguration settled display={} flags=0x{x} links={} surfaces={}",
        .{ display, flags, displays.items.len, live.items.len },
    );

    // Any live subscription will do as the carrier; `settled` ignores it. If
    // there are none there is nothing to re-assert.
    const carrier = if (live.items.len > 0) live.items[0] else return;
    carrier.post(.settled);
}

/// The one CVDisplayLink for one physical display, shared by every surface on
/// it.
///
/// Owned by the `displays` list and only ever touched on the main thread,
/// except for `slots` and `slot_count`, which the IO thread reads.
const Display = struct {
    /// A published surface, or null for a free slot.
    const Slot = std.atomic.Value(?*Subscription);

    /// The display this link is bound to, or `no_display`.
    id: u32,

    /// MAIN THREAD ONLY.
    link: ?*macos.video.DisplayLink = null,

    /// The surfaces to notify on each vsync.
    ///
    /// Written only on the main thread, read on the IO thread. Deliberately a
    /// fixed array of atomics rather than a list: the IO thread can then read
    /// it with plain acquire loads, needing no lock to be consistent and no
    /// reclamation scheme to be safe, which is what keeps it unable to block.
    slots: [max_surfaces_per_display]Slot = @splat(.init(null)),

    /// How far into `slots` the IO thread needs to scan.
    ///
    /// A high water mark, never lowered: shrinking it would race the IO
    /// thread's read for no benefit, and scanning a few null slots per vsync
    /// costs nothing.
    slot_count: std.atomic.Value(u32) = .init(0),

    /// Publish a surface into a free slot, or null if this display is full.
    /// MAIN THREAD ONLY.
    fn claimSlotOnMain(self: *Display, sub: *Subscription) ?u32 {
        const count = self.slot_count.load(.monotonic);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.slots[i].load(.monotonic) != null) continue;
            self.slots[i].store(sub, .release);
            return i;
        }

        if (count == max_surfaces_per_display) return null;

        // Publish the pointer before widening the range the IO thread scans,
        // so it can never see an occupied index holding a stale pointer.
        self.slots[count].store(sub, .release);
        self.slot_count.store(count + 1, .release);
        return count;
    }

    /// MAIN THREAD ONLY.
    fn hasSurfacesOnMain(self: *Display) bool {
        const count = self.slot_count.load(.monotonic);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.slots[i].load(.monotonic) != null) return true;
        }
        return false;
    }

    /// Whether any surface on this display currently wants frames.
    /// MAIN THREAD ONLY.
    ///
    /// Recomputed from the slots rather than kept as a counter: it is only
    /// read when applying, which is rare, and a derived value cannot drift out
    /// of sync with the surfaces it describes.
    fn wantsRunningOnMain(self: *Display) bool {
        const count = self.slot_count.load(.monotonic);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const sub = self.slots[i].load(.monotonic) orelse continue;
            if (sub.wants_running.load(.monotonic)) return true;
        }
        return false;
    }

    /// Make CoreVideo match what this display's surfaces want.
    /// MAIN THREAD ONLY.
    fn applyOnMain(self: *Display) void {
        const wants_running = self.wantsRunningOnMain();

        // Create lazily, and retry here if an earlier create failed because
        // the session had no active displays.
        if (self.link == null and wants_running) self.createOnMain();

        const link = self.link orelse {
            // No link means no vsync, so the render threads have to draw for
            // themselves. Say so rather than leaving a stale `true` behind.
            self.broadcastRunningOnMain(false);
            return;
        };

        // Bind to the right display. CoreVideo can reset this across a
        // configuration change, so we check what it actually thinks rather
        // than trusting what we asked for last time -- but we only set it
        // when it really differs, because setting it restarts the IO thread.
        if (self.id != no_display and link.getCurrentCGDisplay() != self.id) {
            log.info("updating display link display id={}", .{self.id});
            link.setCurrentCGDisplay(self.id) catch |err| log.warn(
                "error setting display link display id={} err={}",
                .{ self.id, err },
            );
        }

        // Start or stop only on a real transition. Redundant starts and stops
        // return errors and, more importantly, are pointless work inside
        // CoreVideo's locks.
        if (wants_running != link.isRunning()) {
            if (wants_running) {
                link.start() catch |err|
                    log.warn("error starting display link err={}", .{err});
            } else {
                link.stop() catch |err|
                    log.warn("error stopping display link err={}", .{err});
            }
        }

        // Cache CoreVideo's real state. This is the only place that asks, and
        // we're on the main thread, so it can't race the reconfiguration
        // handler.
        self.broadcastRunningOnMain(link.isRunning());
    }

    /// Push the link's real state down to every surface on it, so each one's
    /// per-frame `isRunning` is a plain atomic load. MAIN THREAD ONLY.
    fn broadcastRunningOnMain(self: *Display, running: bool) void {
        const count = self.slot_count.load(.monotonic);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const sub = self.slots[i].load(.monotonic) orelse continue;

            // A surface that doesn't want frames isn't getting them even
            // though the link is up for its neighbours.
            const driven = running and sub.wants_running.load(.monotonic);
            sub.running.store(driven, .release);
        }
    }

    /// MAIN THREAD ONLY. Asserts we don't already have a link.
    fn createOnMain(self: *Display) void {
        std.debug.assert(self.link == null);

        const link = macos.video.DisplayLink.createWithActiveCGDisplays() catch |err| {
            // A locked or sleeping macOS session can temporarily have no
            // active displays. Rendering continues without vsync and the next
            // apply retries this.
            log.warn(
                "error creating display link; using fallback rendering err={}",
                .{err},
            );
            return;
        };

        link.setOutputCallback(
            Display,
            &displayCallback,
            self,
        ) catch |err| {
            log.warn("error configuring display link err={}", .{err});
            link.release();
            return;
        };

        self.link = link;
        log.info("created display link display={}", .{self.id});
    }

    /// MAIN THREAD ONLY. Frees the owner; callers must remove it from
    /// `displays` and must not leave any surface attached to it.
    fn destroyOnMain(self: *Display) void {
        std.debug.assert(!self.hasSurfacesOnMain());

        if (self.link) |link| {
            // Safe to stop here precisely because we're on the main thread
            // and therefore cannot be racing CoreVideo's reconfiguration
            // handler.
            link.stop() catch {};
            link.release();
            log.info("released display link display={}", .{self.id});
        }

        global.alloc().destroy(self);
    }
};

/// Called on the shared link's own IO thread, once per vsync, to wake every
/// surface on that display.
///
/// This must never block, and the fan-out is lock-free so that it cannot. A
/// mutex around `slots` would reintroduce the deadlock this file exists to
/// prevent: `CVDisplayLinkStop` on the main thread waits for this callback to
/// return, so anything this thread waits for that the main thread can hold
/// hangs the whole app. `xev.Async.notify` is a mach message send with a zero
/// send timeout that treats a full port as success, so it cannot block either,
/// and it must stay that way.
fn displayCallback(
    _: *macos.video.DisplayLink,
    ud: ?*Display,
) void {
    const display = ud orelse return;

    const count = display.slot_count.load(.acquire);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const sub = display.slots[i].load(.acquire) orelse continue;
        if (!sub.wants_running.load(.monotonic)) continue;

        sub.draw_now.notify() catch |err| {
            log.err("error notifying draw_now err={}", .{err});
        };
    }
}

/// A subscription that is only ever inspected for its atomic fields. The
/// `draw_now` pointer is real storage so the value is well formed, but nothing
/// under test dereferences it.
fn testSubscription(draw_now: *xev.Async) Subscription {
    return .{ .alloc = std.testing.allocator, .draw_now = draw_now };
}

test "Display: slots are claimed in order and freed slots are reused" {
    const testing = std.testing;

    var draw_now: xev.Async = undefined;
    var display: Display = .{ .id = 1 };
    var subs: [3]Subscription = undefined;
    for (&subs) |*sub| sub.* = testSubscription(&draw_now);

    try testing.expect(!display.hasSurfacesOnMain());

    try testing.expectEqual(@as(?u32, 0), display.claimSlotOnMain(&subs[0]));
    try testing.expectEqual(@as(?u32, 1), display.claimSlotOnMain(&subs[1]));
    try testing.expectEqual(@as(?u32, 2), display.claimSlotOnMain(&subs[2]));
    try testing.expectEqual(@as(u32, 3), display.slot_count.load(.monotonic));
    try testing.expect(display.hasSurfacesOnMain());

    // A surface leaving frees its slot for the next one, so churning surfaces
    // doesn't widen the range the IO thread has to scan.
    display.slots[1].store(null, .monotonic);
    try testing.expectEqual(@as(?u32, 1), display.claimSlotOnMain(&subs[1]));
    try testing.expectEqual(@as(u32, 3), display.slot_count.load(.monotonic));

    for (&subs, 0..) |_, i| display.slots[i].store(null, .monotonic);
    try testing.expect(!display.hasSurfacesOnMain());
}

test "Display: a full display refuses further surfaces" {
    const testing = std.testing;

    var draw_now: xev.Async = undefined;
    var display: Display = .{ .id = 2 };
    var sub = testSubscription(&draw_now);

    for (0..max_surfaces_per_display) |_| {
        try testing.expect(display.claimSlotOnMain(&sub) != null);
    }

    // Refusing is how a surface ends up without vsync rather than scribbling
    // past the end of the fan-out array.
    try testing.expectEqual(@as(?u32, null), display.claimSlotOnMain(&sub));
}

test "Display: run state only reaches surfaces that want frames" {
    const testing = std.testing;

    var draw_now: xev.Async = undefined;
    var display: Display = .{ .id = 3 };
    var subs: [2]Subscription = undefined;
    for (&subs) |*sub| sub.* = testSubscription(&draw_now);

    subs[0].wants_running.store(true, .monotonic);
    subs[1].wants_running.store(false, .monotonic);
    _ = display.claimSlotOnMain(&subs[0]);
    _ = display.claimSlotOnMain(&subs[1]);

    // One surface wanting frames is enough to keep the shared link up.
    try testing.expect(display.wantsRunningOnMain());

    display.broadcastRunningOnMain(true);
    try testing.expect(subs[0].isRunning());
    try testing.expect(!subs[1].isRunning());

    // Nothing is driven while the link is down, even a surface that wants it.
    display.broadcastRunningOnMain(false);
    try testing.expect(!subs[0].isRunning());
    try testing.expect(!subs[1].isRunning());

    subs[0].wants_running.store(false, .monotonic);
    try testing.expect(!display.wantsRunningOnMain());
}
