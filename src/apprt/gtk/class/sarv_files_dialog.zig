//! The Sarv "Files" dialog for the GTK app: a single-pane, read-only remote
//! SFTP-style file browser. It lists saved hosts from the cross-platform vault
//! (src/sarv), lets the user pick one, and lists a remote directory by running
//! `ssh … "ls -la --time-style=long-iso <path>"` (built by sarv.sftp) and
//! parsing the output with sarv.sftp.parseLsLine. This is the GTK counterpart
//! of the macOS Files browser.
//!
//! NOTE: reload() spawns the ssh command *synchronously* via std.process.Child
//! (`/bin/sh -c <command>`), captures stdout with readToEndAlloc, and waits for
//! exit. This briefly blocks the UI while the listing is fetched. It also only
//! works for hosts reachable with key/agent auth — no askpass is wired here, so
//! password-auth hosts (and an async, non-blocking spawn) are follow-ups.

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

const log = std.log.scoped(.gtk_sarv_files_dialog);

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
        host_row: *adw.ComboRow,
        host_names: *gtk.StringList,
        path_label: *gtk.Label,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        source: *gio.ListStore,
        empty_label: *gtk.Label,

        /// The saved hosts backing the selector. Loaded once on present and kept
        /// alive for the dialog's lifetime (the ComboRow indexes into it), then
        /// freed in dispose. Null before the first load.
        hosts: ?HostsLoaded = null,

        /// The remote directory currently shown, heap-owned with the app
        /// allocator (managed/freed by setPath and dispose). Defaults to ".".
        current_path: []u8 = "",

        /// Guards host_changed while we repopulate the selector programmatically.
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

        if (priv.current_path.len > 0) {
            gpa.free(priv.current_path);
            priv.current_path = "";
        }
        if (priv.hosts) |*loaded| {
            loaded.deinit();
            priv.hosts = null;
        }

        priv.source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`, loading hosts into the selector and
    /// listing the first host's home-ish directory (".").
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.loadHosts();
        priv.dialog.present(window.as(gtk.Widget));
    }

    /// (Re)load the saved hosts into the ComboRow selector. The previously
    /// loaded set (if any) is freed. Selecting the first host resets the path
    /// and triggers a listing via the notify::selected handler.
    fn loadHosts(self: *Self) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        // Suppress the selection handler while we rebuild the model.
        priv.loading = true;
        defer priv.loading = false;

        // Free any prior load before replacing it.
        if (priv.hosts) |*loaded| {
            loaded.deinit();
            priv.hosts = null;
        }

        // Clear the name model (StringList has no removeAll; splice the whole
        // range out).
        const existing = priv.host_names.as(gio.ListModel).getNItems();
        if (existing > 0) priv.host_names.splice(0, existing, null);

        const loaded = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            self.setPath(".");
            self.reload();
            return;
        };

        for (loaded.items) |*host| {
            const label = if (host.label.len > 0) host.label else host.hostname;
            const label_z = gpa.dupeZ(u8, label) catch continue;
            defer gpa.free(label_z);
            priv.host_names.append(label_z);
        }

        priv.hosts = loaded;

        if (loaded.items.len > 0) {
            priv.host_row.setSelected(0);
        }

        // Selecting the (first) host does not fire notify while `loading` is
        // set, so drive the initial listing explicitly.
        self.setPath(".");
        self.reload();
    }

    /// Replace `current_path` with a fresh heap copy of `path`, update the
    /// label, and free the old value.
    fn setPath(self: *Self, path: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const copy = gpa.dupe(u8, path) catch return;
        if (priv.current_path.len > 0) gpa.free(priv.current_path);
        priv.current_path = copy;

        const label_z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(label_z);
        priv.path_label.setLabel(label_z);
    }

    /// The currently selected host, or null when none is loaded/selected.
    fn selectedHost(self: *Self) ?*const sarv.model.SavedHost {
        const priv = self.private();
        const loaded = priv.hosts orelse return null;
        const idx = priv.host_row.getSelected();
        if (idx >= loaded.items.len) return null;
        return &loaded.items[idx];
    }

    /// List `current_path` on the selected host and repopulate the file list.
    /// Directories are shown first, then files, each group alphabetical.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        const host = self.selectedHost() orelse {
            self.updateEmpty(0);
            return;
        };

        const listing = self.fetchListing(gpa, host) catch |err| {
            log.warn("failed to list remote directory: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer gpa.free(listing);

        // Parse each line into an owned FileEntry, collecting into a list we can
        // sort before wrapping into GObjects. Every entry's name/mtime is duped
        // by parseLsLine from `arena`, so the whole batch is freed together.
        var arena: ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const aalloc = arena.allocator();

        var entries: std.ArrayList(sarv.sftp.FileEntry) = .empty;
        // Backed by the arena; no explicit deinit needed.

        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const entry = sarv.sftp.parseLsLine(aalloc, line) catch continue orelse continue;
            entries.append(aalloc, entry) catch continue;
        }

        std.mem.sort(sarv.sftp.FileEntry, entries.items, {}, lessThan);

        for (entries.items) |*entry| {
            const obj = SarvFile.new(entry) catch |err| {
                log.warn("failed to wrap file entry: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }

        self.updateEmpty(entries.items.len);
    }

    /// Directories sort before files; within a group, case-insensitive by name.
    fn lessThan(_: void, a: sarv.sftp.FileEntry, b: sarv.sftp.FileEntry) bool {
        if (a.isDir != b.isDir) return a.isDir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Build the remote listing command for `host`/`current_path`, spawn it via
    /// `/bin/sh -c <command>`, capture stdout and wait. Caller owns the result.
    ///
    /// This is a synchronous spawn — it blocks until ssh exits. See the file
    /// header for the auth/async caveats.
    fn fetchListing(self: *Self, gpa: Allocator, host: *const sarv.model.SavedHost) ![]u8 {
        const priv = self.private();

        const command = try sarv.sftp.remoteListCommand(gpa, host, priv.current_path);
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

    fn updateEmpty(self: *Self, count: usize) void {
        self.private().empty_label.as(gtk.Widget).setVisible(@intFromBool(count == 0));
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    fn hostChanged(_: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        // Ignore selection changes we make while (re)building the model.
        if (self.private().loading) return;
        // Switching hosts resets to the top-level path and relists.
        self.setPath(".");
        self.reload();
    }

    fn reloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.reload();
    }

    fn upClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.goUp();
    }

    /// Navigate to the parent of `current_path` and relist. "." and "/" have no
    /// parent, so those are no-ops.
    fn goUp(self: *Self) void {
        const priv = self.private();
        const path = priv.current_path;

        if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return;

        // Trim any trailing slash before finding the last separator.
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0) return;

        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
            const parent = if (idx == 0) "/" else trimmed[0..idx];
            self.setPath(parent);
        } else {
            // A single relative segment (e.g. "projects"): parent is ".".
            self.setPath(".");
        }
        self.reload();
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        self.enter(pos);
    }

    /// On a directory, descend into it (append its name to current_path and
    /// relist). On a file, do nothing (v1 is read-only browsing).
    fn enter(self: *Self, pos: c_uint) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvFile, object_ orelse return) orelse return;
        if (!wrapper.getIsDir()) return;
        const name = wrapper.getName() orelse return;

        // Build "<current>/<name>", collapsing the "." base to a bare name.
        const child_path = blk: {
            if (std.mem.eql(u8, priv.current_path, ".") or priv.current_path.len == 0) {
                break :blk gpa.dupe(u8, name) catch return;
            }
            const sep: []const u8 = if (std.mem.endsWith(u8, priv.current_path, "/")) "" else "/";
            break :blk std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ priv.current_path, sep, name }) catch return;
        };
        defer gpa.free(child_path);

        self.setPath(child_path);
        self.reload();
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
            class.bindTemplateChildPrivate("host_row", .{});
            class.bindTemplateChildPrivate("host_names", .{});
            class.bindTemplateChildPrivate("path_label", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("host_changed", &hostChanged);
            class.bindTemplateCallback("reload_clicked", &reloadClicked);
            class.bindTemplateCallback("up_clicked", &upClicked);
            class.bindTemplateCallback("row_activated", &rowActivated);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one remote file entry for the list model. Holds the
/// display strings plus the raw name and directory flag used for navigation;
/// all strings live in a per-object arena.
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
