//! The Sarv "Files" dialog for the GTK app: a DUAL-PANE endpoint file browser,
//! the GTK counterpart of the macOS Files browser.
//!
//! BOTH panes are identical "endpoint" browsers. Each pane has a Gtk.DropDown
//! whose entries are: "Local", "Demo (sample)", then each saved vault host.
//! Endpoint mapping per pane by dropdown index:
//!   0        => Local filesystem (via sarv.sftp.listLocal — no SSH, offline).
//!   1        => Demo (sarv.sftp.sampleEntries — static, no spawn).
//!   n >= 2   => the saved vault host at hosts.items[n - 2].
//! Defaults: left = index 0 (Local), right = index 1 (Demo).
//!
//! For a real host the remote listing is fetched by running
//! `ssh … "ls -la --time-style=long-iso <path>"` (built by sarv.sftp) via
//! `/bin/sh -c <command>` and parsing the output with sarv.sftp.parseLsLine.
//!
//! NOTE: the remote fetch spawns ssh *synchronously* via std.process.Child,
//! captures stdout with readToEndAlloc, and waits for exit. This briefly blocks
//! the UI. It only works for hosts reachable with key/agent auth — no askpass
//! is wired here, so password-auth hosts (and an async spawn) are follow-ups.
//!
//! Transfers are REAL scp now: the center "→"/"←" buttons compose the correct
//! scp command (upload / download / server-to-server) and spawn it via
//! `/bin/sh -c <command>` (synchronously — briefly blocks the UI, and only
//! works for key/agent-auth hosts; askpass + async are follow-ups). Local↔Local
//! copies use std.fs directly. On success the destination pane is reloaded so
//! the new file appears.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const sarv = @import("../../../sarv/main.zig");
const gresource = @import("../build/gresource.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const HostsLoaded = sarv.store.Store(sarv.model.SavedHost).Loaded;

/// Dropdown index reserved for the Local filesystem endpoint.
const local_index: c_uint = 0;
/// Dropdown index reserved for the built-in Demo listing. Saved vault hosts
/// follow it (host index = dropdown index - 2).
const demo_index: c_uint = 1;
/// First dropdown index that maps to a saved vault host.
const host_base_index: c_uint = 2;

const log = std.log.scoped(.gtk_sarv_files_dialog);

/// Which pane a helper operates on.
const Side = enum { left, right };

/// The kind of endpoint a pane's dropdown currently points at.
const Endpoint = union(enum) {
    local,
    demo,
    host: *const sarv.model.SavedHost,
};

pub const SarvFilesDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvFilesDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The window this dialog belongs to.
        window: WeakRef(Window) = .empty,
        dialog: *adw.Dialog,

        // Left pane.
        left_dropdown: *gtk.DropDown,
        left_names: *gtk.StringList,
        left_path: *gtk.Label,
        left_view: *gtk.ListView,
        left_model: *gtk.SingleSelection,
        left_source: *gio.ListStore,

        // Right pane.
        right_dropdown: *gtk.DropDown,
        right_names: *gtk.StringList,
        right_path: *gtk.Label,
        right_view: *gtk.ListView,
        right_model: *gtk.SingleSelection,
        right_source: *gio.ListStore,

        status_label: *gtk.Label,

        /// The saved hosts backing the (post-Demo entries of the) dropdowns.
        /// Loaded once on present, kept alive for the dialog's lifetime (both
        /// dropdowns index into it), then freed in dispose.
        hosts: ?HostsLoaded = null,

        /// The directory currently shown in each pane, heap-owned (managed/freed
        /// by setPath and dispose). Defaults to "".
        left_dir: []u8 = "",
        right_dir: []u8 = "",

        /// Guards the *_changed handlers while we repopulate the dropdowns
        /// programmatically.
        loading: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        if (priv.left_dir.len > 0) {
            gpa.free(priv.left_dir);
            priv.left_dir = "";
        }
        if (priv.right_dir.len > 0) {
            gpa.free(priv.right_dir);
            priv.right_dir = "";
        }
        if (priv.hosts) |*loaded| {
            loaded.deinit();
            priv.hosts = null;
        }

        priv.left_source.removeAll();
        priv.right_source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`: load the vault hosts into both
    /// dropdowns, default left = Local (at $HOME) and right = Demo, then list
    /// both panes.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);

        self.loadHosts();

        // Defaults: left = Local ($HOME), right = Demo.
        const home = std.posix.getenv("HOME") orelse "/";
        self.setPath(.left, home);
        self.setPath(.right, ".");

        self.reload(.left);
        self.reload(.right);

        priv.dialog.present(window.as(gtk.Widget));
    }

    // -----------------------------------------------------------------------
    // Per-side accessors
    // -----------------------------------------------------------------------

    fn dropdown(self: *Self, side: Side) *gtk.DropDown {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_dropdown,
            .right => priv.right_dropdown,
        };
    }

    fn names(self: *Self, side: Side) *gtk.StringList {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_names,
            .right => priv.right_names,
        };
    }

    fn pathLabel(self: *Self, side: Side) *gtk.Label {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_path,
            .right => priv.right_path,
        };
    }

    fn model(self: *Self, side: Side) *gtk.SingleSelection {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_model,
            .right => priv.right_model,
        };
    }

    fn source(self: *Self, side: Side) *gio.ListStore {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_source,
            .right => priv.right_source,
        };
    }

    /// The directory currently shown by `side` (borrowed; do not free).
    fn dir(self: *Self, side: Side) []const u8 {
        const priv = self.private();
        return switch (side) {
            .left => priv.left_dir,
            .right => priv.right_dir,
        };
    }

    // -----------------------------------------------------------------------
    // Path helpers
    // -----------------------------------------------------------------------

    /// Replace the pane's dir with a fresh heap copy of `path`, update the
    /// label, and free the old value.
    fn setPath(self: *Self, side: Side, path: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const copy = gpa.dupe(u8, path) catch return;
        switch (side) {
            .left => {
                if (priv.left_dir.len > 0) gpa.free(priv.left_dir);
                priv.left_dir = copy;
            },
            .right => {
                if (priv.right_dir.len > 0) gpa.free(priv.right_dir);
                priv.right_dir = copy;
            },
        }

        const label_z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(label_z);
        self.pathLabel(side).setLabel(label_z);
    }

    /// Compute the parent of `path` (string-only, never above "/") and return a
    /// heap copy the caller owns, or null when there is no parent to go to.
    fn parentPath(gpa: Allocator, path: []const u8) ?[]u8 {
        if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return null;

        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0) return null;

        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
            const parent = if (idx == 0) "/" else trimmed[0..idx];
            return gpa.dupe(u8, parent) catch null;
        }
        // A single relative segment (e.g. "projects"): parent is ".".
        return gpa.dupe(u8, ".") catch null;
    }

    /// Join `base` and `name` into a child path the caller owns, collapsing a
    /// "." base to a bare name and avoiding a double slash after "/".
    fn childPath(gpa: Allocator, base: []const u8, name: []const u8) ?[]u8 {
        if (std.mem.eql(u8, base, ".") or base.len == 0) {
            return gpa.dupe(u8, name) catch null;
        }
        const sep: []const u8 = if (std.mem.endsWith(u8, base, "/")) "" else "/";
        return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ base, sep, name }) catch null;
    }

    // -----------------------------------------------------------------------
    // Endpoints
    // -----------------------------------------------------------------------

    /// (Re)load the saved hosts into both dropdowns: "Local" at index 0,
    /// "Demo (sample)" at index 1, then each vault host label. Sets the default
    /// selection for each side (left = Local, right = Demo).
    fn loadHosts(self: *Self) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        // Suppress the selection handlers while we rebuild the models.
        priv.loading = true;
        defer priv.loading = false;

        // Free any prior load before replacing it.
        if (priv.hosts) |*loaded| {
            loaded.deinit();
            priv.hosts = null;
        }

        self.resetNames(.left);
        self.resetNames(.right);

        const loaded = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            self.dropdown(.left).setSelected(local_index);
            self.dropdown(.right).setSelected(demo_index);
            return;
        };

        for (loaded.items) |*host| {
            const label = if (host.label.len > 0) host.label else host.hostname;
            const label_z = gpa.dupeZ(u8, label) catch continue;
            defer gpa.free(label_z);
            self.names(.left).append(label_z);
            self.names(.right).append(label_z);
        }

        priv.hosts = loaded;
        self.dropdown(.left).setSelected(local_index);
        self.dropdown(.right).setSelected(demo_index);
    }

    /// Clear a pane's name model (StringList has no removeAll; splice out the
    /// whole range) and seed the fixed "Local"/"Demo (sample)" entries.
    fn resetNames(self: *Self, side: Side) void {
        const list = self.names(side);
        const existing = list.as(gio.ListModel).getNItems();
        if (existing > 0) list.splice(0, existing, null);
        list.append("Local");
        list.append("Demo (sample)");
    }

    /// The endpoint the pane's dropdown currently points at.
    fn endpoint(self: *Self, side: Side) Endpoint {
        const idx = self.dropdown(side).getSelected();
        if (idx == local_index) return .local;
        if (idx == demo_index) return .demo;
        const loaded = self.private().hosts orelse return .demo;
        const host_idx = idx - host_base_index;
        if (host_idx >= loaded.items.len) return .demo;
        return .{ .host = &loaded.items[host_idx] };
    }

    // -----------------------------------------------------------------------
    // Reload (shared by both panes)
    // -----------------------------------------------------------------------

    /// List the pane's current directory for its selected endpoint and
    /// repopulate its file list. Each entry's display strings are duped into the
    /// per-item arena, so any transient Listing can be freed immediately.
    fn reload(self: *Self, side: Side) void {
        const store = self.source(side);
        store.removeAll();

        const gpa = Application.default().allocator();

        switch (self.endpoint(side)) {
            .local => {
                var listing = sarv.sftp.listLocal(gpa, self.dir(side)) catch |err| {
                    log.warn("failed to list local directory: {}", .{err});
                    self.setStatus("Cannot read local directory.");
                    return;
                };
                defer listing.deinit();

                for (listing.entries) |*entry| {
                    const obj = SarvFile.new(entry) catch continue;
                    defer obj.unref();
                    store.append(obj.as(gobject.Object));
                }
            },
            .demo => {
                for (sarv.sftp.sampleEntries()) |*entry| {
                    const obj = SarvFile.new(entry) catch continue;
                    defer obj.unref();
                    store.append(obj.as(gobject.Object));
                }
                self.setStatus("Showing the built-in demo listing.");
            },
            .host => |host| self.reloadHost(side, gpa, host),
        }
    }

    /// List `dir(side)` on `host` via a synchronous ssh spawn, parse, sort and
    /// wrap into the pane's store.
    fn reloadHost(self: *Self, side: Side, gpa: Allocator, host: *const sarv.model.SavedHost) void {
        const store = self.source(side);

        const listing = self.fetchListing(gpa, host, self.dir(side)) catch |err| {
            log.warn("failed to list remote directory: {}", .{err});
            self.setStatus("No files (host unreachable or empty).");
            return;
        };
        defer gpa.free(listing);

        // Parse each line into an owned FileEntry in an arena, sort, then wrap.
        var arena: ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const aalloc = arena.allocator();

        var entries: std.ArrayList(sarv.sftp.FileEntry) = .empty;

        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const entry = sarv.sftp.parseLsLine(aalloc, line) catch continue orelse continue;
            entries.append(aalloc, entry) catch continue;
        }

        std.mem.sort(sarv.sftp.FileEntry, entries.items, {}, lessThan);

        for (entries.items) |*entry| {
            const obj = SarvFile.new(entry) catch continue;
            defer obj.unref();
            store.append(obj.as(gobject.Object));
        }

        if (entries.items.len == 0) {
            self.setStatus("No files (host unreachable or empty).");
        } else {
            self.setStatus("Connected.");
        }
    }

    /// Directories sort before files; within a group, case-insensitive by name.
    fn lessThan(_: void, a: sarv.sftp.FileEntry, b: sarv.sftp.FileEntry) bool {
        if (a.isDir != b.isDir) return a.isDir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Build the remote listing command for `host`/`path`, spawn it via
    /// `/bin/sh -c <command>`, capture stdout and wait. Caller owns the result.
    /// Synchronous — blocks until ssh exits (see the file header caveats).
    fn fetchListing(self: *Self, gpa: Allocator, host: *const sarv.model.SavedHost, path: []const u8) ![]u8 {
        _ = self;
        const command = try sarv.sftp.remoteListCommand(gpa, host, path);
        defer gpa.free(command);

        var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, gpa);
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout orelse {
            _ = child.wait() catch {};
            return error.NoStdout;
        };
        const out = try stdout.readToEndAlloc(gpa, 8 * 1024 * 1024);
        errdefer gpa.free(out);

        _ = child.wait() catch {};
        return out;
    }

    // -----------------------------------------------------------------------
    // Navigation callbacks
    // -----------------------------------------------------------------------

    fn activated(self: *Self, side: Side, pos: c_uint) void {
        const gpa = Application.default().allocator();

        const object_ = self.model(side).as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvFile, object_ orelse return) orelse return;
        if (!wrapper.getIsDir()) return;

        // For the demo endpoint, descending has no real backing directory —
        // just re-show the sample listing so the UI stays responsive.
        if (self.endpoint(side) == .demo) {
            self.reload(side);
            return;
        }

        const name = wrapper.getName() orelse return;
        const child = childPath(gpa, self.dir(side), name) orelse return;
        defer gpa.free(child);
        self.setPath(side, child);
        self.reload(side);
    }

    fn upClicked(self: *Self, side: Side) void {
        const gpa = Application.default().allocator();
        const parent = parentPath(gpa, self.dir(side)) orelse return;
        defer gpa.free(parent);
        self.setPath(side, parent);
        self.reload(side);
    }

    /// A dropdown selection changed: switch endpoints, reset the path and
    /// relist. Local defaults to $HOME; Demo/host default to ".".
    fn endpointChanged(self: *Self, side: Side) void {
        if (self.private().loading) return;
        switch (self.endpoint(side)) {
            .local => self.setPath(side, std.posix.getenv("HOME") orelse "/"),
            else => self.setPath(side, "."),
        }
        self.reload(side);
    }

    fn leftActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        self.activated(.left, pos);
    }
    fn rightActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        self.activated(.right, pos);
    }
    fn leftUpClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.upClicked(.left);
    }
    fn rightUpClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.upClicked(.right);
    }
    fn leftChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.endpointChanged(.left);
    }
    fn rightChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.endpointChanged(.right);
    }

    // -----------------------------------------------------------------------
    // Transfers (real scp)
    // -----------------------------------------------------------------------

    /// The selected entry in `side`, or null when none.
    fn selected(self: *Self, side: Side) ?*SarvFile {
        const sel = self.model(side);
        const idx = sel.getSelected();
        const object_ = sel.as(gio.ListModel).getObject(idx) orelse return null;
        // getObject added a ref; drop it — the store keeps its own and the
        // caller only reads immediately.
        defer object_.unref();
        return gobject.ext.cast(SarvFile, object_);
    }

    fn copyRightClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.transfer(.left, .right);
    }
    fn copyLeftClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.transfer(.right, .left);
    }

    /// Copy the selected file in `src` to the current directory of `dst` using
    /// real scp (or std.fs for Local→Local). Synchronous — briefly blocks the
    /// UI and only works for key/agent-auth hosts (askpass + async are
    /// follow-ups). On success the destination pane is reloaded.
    fn transfer(self: *Self, src: Side, dst: Side) void {
        const gpa = Application.default().allocator();

        const wrapper = self.selected(src) orelse {
            self.setStatus("Select a file to transfer.");
            return;
        };
        const name = wrapper.getName() orelse return;
        const is_dir = wrapper.getIsDir();

        const src_ep = self.endpoint(src);
        const dst_ep = self.endpoint(dst);

        // Demo is not a real endpoint for transfers.
        if (src_ep == .demo or dst_ep == .demo) {
            self.setStatus("Pick a real host (not Demo) to transfer.");
            return;
        }

        // Source path: <src dir>/<name>. Destination path: <dst dir>/<name>.
        const src_full = childPath(gpa, self.dir(src), name) orelse return;
        defer gpa.free(src_full);
        const dst_full = childPath(gpa, self.dir(dst), name) orelse return;
        defer gpa.free(dst_full);

        switch (src_ep) {
            .local => switch (dst_ep) {
                // Local → Local: pure filesystem copy.
                .local => {
                    if (is_dir) {
                        self.setStatus("directory copy not supported yet");
                        return;
                    }
                    std.fs.cwd().copyFile(src_full, std.fs.cwd(), dst_full, .{}) catch |err| {
                        log.warn("local copy failed: {}", .{err});
                        self.setStatus("Transfer failed (local copy).");
                        return;
                    };
                    self.reportTransferred(name);
                    self.reload(dst);
                },
                // Local → Host: scp upload.
                .host => |dst_host| {
                    const cmd = sarv.sftp.scpUpload(gpa, dst_host, src_full, dst_full, is_dir) catch {
                        self.setStatus("Failed to build the transfer command.");
                        return;
                    };
                    defer gpa.free(cmd);
                    self.runTransfer(cmd, name, dst);
                },
                .demo => unreachable,
            },
            .host => |src_host| switch (dst_ep) {
                // Host → Local: scp download.
                .local => {
                    const cmd = sarv.sftp.scpDownload(gpa, src_host, src_full, dst_full, is_dir) catch {
                        self.setStatus("Failed to build the transfer command.");
                        return;
                    };
                    defer gpa.free(cmd);
                    self.runTransfer(cmd, name, dst);
                },
                // Host → Host: scp server-to-server relay.
                .host => |dst_host| {
                    const cmd = sarv.sftp.scpServerToServer(gpa, src_host, src_full, dst_host, dst_full, is_dir) catch {
                        self.setStatus("Failed to build the transfer command.");
                        return;
                    };
                    defer gpa.free(cmd);
                    self.runTransfer(cmd, name, dst);
                },
                .demo => unreachable,
            },
            .demo => unreachable,
        }
    }

    /// Spawn `command` via `/bin/sh -c <command>` and wait. Reports success or
    /// failure in the status bar; on success reloads `dst`. Synchronous — see
    /// the transfer() caveats. `command` is borrowed (caller frees).
    fn runTransfer(self: *Self, command: []const u8, name: []const u8, dst: Side) void {
        const gpa = Application.default().allocator();

        const command_z = gpa.dupeZ(u8, command) catch return;
        defer gpa.free(command_z);

        var child = std.process.Child.init(&.{ "/bin/sh", "-c", command_z }, gpa);
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            log.warn("failed to spawn transfer: {}", .{err});
            self.setStatus("Transfer failed (could not spawn).");
            return;
        };

        const term = child.wait() catch |err| {
            log.warn("transfer wait failed: {}", .{err});
            self.setStatus("Transfer failed (wait error).");
            return;
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    self.reportTransferred(name);
                    self.reload(dst);
                } else {
                    self.reportFailed(code);
                }
            },
            else => self.reportFailed(1),
        }
    }

    fn reportTransferred(self: *Self, name: []const u8) void {
        const gpa = Application.default().allocator();
        const msg = std.fmt.allocPrintSentinel(gpa, "Transferred {s}", .{name}, 0) catch return;
        defer gpa.free(msg);
        self.private().status_label.setLabel(msg);
    }

    fn reportFailed(self: *Self, code: u32) void {
        const gpa = Application.default().allocator();
        const msg = std.fmt.allocPrintSentinel(gpa, "Transfer failed ({d})", .{code}, 0) catch return;
        defer gpa.free(msg);
        self.private().status_label.setLabel(msg);
    }

    // -----------------------------------------------------------------------
    // Misc
    // -----------------------------------------------------------------------

    fn setStatus(self: *Self, comptime text: [:0]const u8) void {
        self.private().status_label.setLabel(text);
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(SarvFile);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-files-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});

            class.bindTemplateChildPrivate("left_dropdown", .{});
            class.bindTemplateChildPrivate("left_names", .{});
            class.bindTemplateChildPrivate("left_path", .{});
            class.bindTemplateChildPrivate("left_view", .{});
            class.bindTemplateChildPrivate("left_model", .{});
            class.bindTemplateChildPrivate("left_source", .{});

            class.bindTemplateChildPrivate("right_dropdown", .{});
            class.bindTemplateChildPrivate("right_names", .{});
            class.bindTemplateChildPrivate("right_path", .{});
            class.bindTemplateChildPrivate("right_view", .{});
            class.bindTemplateChildPrivate("right_model", .{});
            class.bindTemplateChildPrivate("right_source", .{});

            class.bindTemplateChildPrivate("status_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("left_changed", &leftChanged);
            class.bindTemplateCallback("left_activated", &leftActivated);
            class.bindTemplateCallback("left_up_clicked", &leftUpClicked);
            class.bindTemplateCallback("right_changed", &rightChanged);
            class.bindTemplateCallback("right_activated", &rightActivated);
            class.bindTemplateCallback("right_up_clicked", &rightUpClicked);
            class.bindTemplateCallback("copy_right_clicked", &copyRightClicked);
            class.bindTemplateCallback("copy_left_clicked", &copyLeftClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one file entry (local or remote) for the list model.
/// Holds the display strings plus the raw name and directory flag used for
/// navigation; all strings live in a per-object arena, so panes can be cleared
/// and reloaded freely and the source Listing can be freed immediately.
const SarvFile = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvFile",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const label = defineStr("label", propGetLabel);
        pub const subtitle = defineStr("subtitle", propGetSubtitle);
        pub const @"icon-name" = defineStr("icon-name", propGetIconName);

        fn defineStr(
            comptime name: [:0]const u8,
            comptime getter: fn (*Self) ?[:0]const u8,
        ) type {
            return struct {
                pub const impl = gobject.ext.defineProperty(name, Self, ?[:0]const u8, .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(Self, ?[:0]const u8, .{
                        .getter = getter,
                        .getter_transfer = .none,
                    }),
                });
            };
        }
    };

    const Private = struct {
        arena: ArenaAllocator,
        name: ?[:0]const u8 = null,
        label: ?[:0]const u8 = null,
        subtitle: ?[:0]const u8 = null,
        icon_name: ?[:0]const u8 = null,
        is_dir: bool = false,
        pub var offset: c_int = 0;
    };

    pub fn new(entry: *const sarv.sftp.FileEntry) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.is_dir = entry.isDir;
        priv.name = try alloc.dupeZ(u8, entry.name);
        priv.label = try alloc.dupeZ(u8, entry.name);

        const kind = if (entry.isDir)
            "directory"
        else if (entry.symlink)
            "link"
        else
            "file";

        // subtitle: "<human size> · <kind>". Directories show a dash for size.
        if (entry.isDir) {
            priv.subtitle = try std.fmt.allocPrintSentinel(alloc, "— · {s}", .{kind}, 0);
        } else {
            const size = try humanSize(alloc, entry.size);
            defer alloc.free(size);
            priv.subtitle = try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ size, kind }, 0);
        }

        const icon = if (entry.isDir)
            "folder-symbolic"
        else if (entry.symlink)
            "emblem-symbolic-link"
        else
            "text-x-generic-symbolic";
        priv.icon_name = try alloc.dupeZ(u8, icon);

        return self;
    }

    /// Format a byte count as a short human-readable string (e.g. "1.2 KB").
    /// Caller owns the result.
    fn humanSize(alloc: Allocator, bytes: u64) ![]u8 {
        const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        if (bytes < 1024) return std.fmt.allocPrint(alloc, "{d} {s}", .{ bytes, units[0] });

        var value: f64 = @floatFromInt(bytes);
        var unit: usize = 0;
        while (value >= 1024 and unit < units.len - 1) : (unit += 1) {
            value /= 1024;
        }
        return std.fmt.allocPrint(alloc, "{d:.1} {s}", .{ value, units[unit] });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    pub fn getName(self: *Self) ?[:0]const u8 {
        return self.private().name;
    }

    pub fn getIsDir(self: *Self) bool {
        return self.private().is_dir;
    }

    fn propGetLabel(self: *Self) ?[:0]const u8 {
        return self.private().label;
    }
    fn propGetSubtitle(self: *Self) ?[:0]const u8 {
        return self.private().subtitle;
    }
    fn propGetIconName(self: *Self) ?[:0]const u8 {
        return self.private().icon_name;
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.label.impl,
                properties.subtitle.impl,
                properties.@"icon-name".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
