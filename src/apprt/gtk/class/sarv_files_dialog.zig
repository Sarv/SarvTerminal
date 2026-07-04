//! The Sarv "Files" dialog for the GTK app: a DUAL-PANE (local ↔ remote)
//! file browser, the GTK counterpart of the macOS Files browser.
//!
//! LEFT pane lists the LOCAL filesystem (via sarv.sftp.listLocal — no SSH, so
//! it works offline and is fully testable). RIGHT pane lists a REMOTE host
//! chosen from a dropdown: index 0 is a built-in "Demo (sample)" listing
//! (sarv.sftp.sampleEntries, no spawn), and the remaining entries are the saved
//! vault hosts. For a real host the remote listing is fetched by running
//! `ssh … "ls -la --time-style=long-iso <path>"` (built by sarv.sftp) via
//! `/bin/sh -c <command>` and parsing the output with sarv.sftp.parseLsLine.
//!
//! NOTE: the remote fetch spawns ssh *synchronously* via std.process.Child,
//! captures stdout with readToEndAlloc, and waits for exit. This briefly blocks
//! the UI. It only works for hosts reachable with key/agent auth — no askpass
//! is wired here, so password-auth hosts (and an async spawn) are follow-ups.
//!
//! NOTE: the transfer buttons (→ upload, ← download) DO NOT actually spawn scp
//! in this version — they only compose the scp command and report it in the
//! status bar. Real transfers (with progress + askpass) are a follow-up.

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

/// The dropdown index reserved for the built-in demo listing; real vault hosts
/// follow it (host index = dropdown index - 1).
const demo_index: c_uint = 0;

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

        // Local pane.
        local_path: *gtk.Label,
        local_view: *gtk.ListView,
        local_model: *gtk.SingleSelection,
        local_source: *gio.ListStore,

        // Remote pane.
        host_dropdown: *gtk.DropDown,
        host_names: *gtk.StringList,
        remote_path: *gtk.Label,
        remote_view: *gtk.ListView,
        remote_model: *gtk.SingleSelection,
        remote_source: *gio.ListStore,

        status_label: *gtk.Label,

        /// The saved hosts backing the (post-demo entries of the) dropdown.
        /// Loaded once on present, kept alive for the dialog's lifetime (the
        /// dropdown indexes into it), then freed in dispose.
        hosts: ?HostsLoaded = null,

        /// The local directory currently shown, heap-owned (managed/freed by
        /// setLocalPath and dispose). Defaults to "".
        local_dir: []u8 = "",

        /// The remote directory currently shown, heap-owned (managed/freed by
        /// setRemotePath and dispose). Defaults to "".
        remote_dir: []u8 = "",

        /// Guards host_changed while we repopulate the dropdown programmatically.
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

        if (priv.local_dir.len > 0) {
            gpa.free(priv.local_dir);
            priv.local_dir = "";
        }
        if (priv.remote_dir.len > 0) {
            gpa.free(priv.remote_dir);
            priv.remote_dir = "";
        }
        if (priv.hosts) |*loaded| {
            loaded.deinit();
            priv.hosts = null;
        }

        priv.local_source.removeAll();
        priv.remote_source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`: seed the local pane at $HOME, load the
    /// vault hosts into the dropdown and show the demo listing on the right.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);

        const home = std.posix.getenv("HOME") orelse "/";
        self.setLocalPath(home);
        self.reloadLocal();

        self.loadHosts();
        self.reloadRemote();

        priv.dialog.present(window.as(gtk.Widget));
    }

    // -----------------------------------------------------------------------
    // Path helpers
    // -----------------------------------------------------------------------

    /// Replace `local_dir` with a fresh heap copy of `path`, update the label,
    /// and free the old value.
    fn setLocalPath(self: *Self, path: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const copy = gpa.dupe(u8, path) catch return;
        if (priv.local_dir.len > 0) gpa.free(priv.local_dir);
        priv.local_dir = copy;

        const label_z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(label_z);
        priv.local_path.setLabel(label_z);
    }

    /// Replace `remote_dir` with a fresh heap copy of `path`, update the label,
    /// and free the old value.
    fn setRemotePath(self: *Self, path: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const copy = gpa.dupe(u8, path) catch return;
        if (priv.remote_dir.len > 0) gpa.free(priv.remote_dir);
        priv.remote_dir = copy;

        const label_z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(label_z);
        priv.remote_path.setLabel(label_z);
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
    // Local pane
    // -----------------------------------------------------------------------

    /// List `local_dir` and repopulate the local file list. Each entry's
    /// display strings are duped into the per-item arena, so the Listing can be
    /// freed immediately after wrapping.
    fn reloadLocal(self: *Self) void {
        const priv = self.private();
        priv.local_source.removeAll();

        const gpa = Application.default().allocator();

        var listing = sarv.sftp.listLocal(gpa, priv.local_dir) catch |err| {
            log.warn("failed to list local directory: {}", .{err});
            self.setStatus("Cannot read local directory.");
            return;
        };
        defer listing.deinit();

        for (listing.entries) |*entry| {
            const obj = SarvFile.new(entry) catch |err| {
                log.warn("failed to wrap file entry: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.local_source.append(obj.as(gobject.Object));
        }
    }

    fn localActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const object_ = priv.local_model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvFile, object_ orelse return) orelse return;
        if (!wrapper.getIsDir()) return;
        const name = wrapper.getName() orelse return;

        const child = childPath(gpa, priv.local_dir, name) orelse return;
        defer gpa.free(child);
        self.setLocalPath(child);
        self.reloadLocal();
    }

    fn localUpClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();
        const parent = parentPath(gpa, priv.local_dir) orelse return;
        defer gpa.free(parent);
        self.setLocalPath(parent);
        self.reloadLocal();
    }

    // -----------------------------------------------------------------------
    // Remote pane
    // -----------------------------------------------------------------------

    /// (Re)load the saved hosts into the dropdown: "Demo (sample)" at index 0,
    /// then each vault host label. Selecting index 0 resets the remote path.
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

        // Clear the name model (StringList has no removeAll; splice out the
        // whole range).
        const existing = priv.host_names.as(gio.ListModel).getNItems();
        if (existing > 0) priv.host_names.splice(0, existing, null);

        priv.host_names.append("Demo (sample)");

        const loaded = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            priv.host_dropdown.setSelected(demo_index);
            self.setRemotePath(".");
            return;
        };

        for (loaded.items) |*host| {
            const label = if (host.label.len > 0) host.label else host.hostname;
            const label_z = gpa.dupeZ(u8, label) catch continue;
            defer gpa.free(label_z);
            priv.host_names.append(label_z);
        }

        priv.hosts = loaded;
        priv.host_dropdown.setSelected(demo_index);
        self.setRemotePath(".");
    }

    /// The currently selected vault host, or null when the demo entry is
    /// selected (or nothing is loaded).
    fn selectedHost(self: *Self) ?*const sarv.model.SavedHost {
        const priv = self.private();
        const idx = priv.host_dropdown.getSelected();
        if (idx == demo_index) return null;
        const loaded = priv.hosts orelse return null;
        const host_idx = idx - 1;
        if (host_idx >= loaded.items.len) return null;
        return &loaded.items[host_idx];
    }

    /// List `remote_dir` on the selected host (or show the demo listing) and
    /// repopulate the remote file list.
    fn reloadRemote(self: *Self) void {
        const priv = self.private();
        priv.remote_source.removeAll();

        const gpa = Application.default().allocator();

        const host = self.selectedHost() orelse {
            // Demo listing: static entries, no spawn.
            for (sarv.sftp.sampleEntries()) |*entry| {
                const obj = SarvFile.new(entry) catch continue;
                defer obj.unref();
                priv.remote_source.append(obj.as(gobject.Object));
            }
            self.setStatus("Showing the built-in demo listing.");
            return;
        };

        const listing = self.fetchListing(gpa, host) catch |err| {
            log.warn("failed to list remote directory: {}", .{err});
            self.setStatus("No files (host unreachable or empty) — try the Demo host.");
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
            priv.remote_source.append(obj.as(gobject.Object));
        }

        if (entries.items.len == 0) {
            self.setStatus("No files (host unreachable or empty) — try the Demo host.");
        } else {
            self.setStatus("Connected.");
        }
    }

    /// Directories sort before files; within a group, case-insensitive by name.
    fn lessThan(_: void, a: sarv.sftp.FileEntry, b: sarv.sftp.FileEntry) bool {
        if (a.isDir != b.isDir) return a.isDir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Build the remote listing command for `host`/`remote_dir`, spawn it via
    /// `/bin/sh -c <command>`, capture stdout and wait. Caller owns the result.
    /// Synchronous — blocks until ssh exits (see the file header caveats).
    fn fetchListing(self: *Self, gpa: Allocator, host: *const sarv.model.SavedHost) ![]u8 {
        const priv = self.private();

        const command = try sarv.sftp.remoteListCommand(gpa, host, priv.remote_dir);
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

    fn remoteActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const object_ = priv.remote_model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvFile, object_ orelse return) orelse return;
        if (!wrapper.getIsDir()) return;

        // For the demo host, descending has no real backing directory — just
        // re-show the sample listing so the UI stays responsive and crash-free.
        if (self.selectedHost() == null) {
            self.reloadRemote();
            return;
        }

        const name = wrapper.getName() orelse return;
        const child = childPath(gpa, priv.remote_dir, name) orelse return;
        defer gpa.free(child);
        self.setRemotePath(child);
        self.reloadRemote();
    }

    fn remoteUpClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();
        const parent = parentPath(gpa, priv.remote_dir) orelse return;
        defer gpa.free(parent);
        self.setRemotePath(parent);
        self.reloadRemote();
    }

    fn hostChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        // Ignore selection changes we make while (re)building the model.
        if (self.private().loading) return;
        // Switching hosts resets to the top-level path and relists.
        self.setRemotePath(".");
        self.reloadRemote();
    }

    // -----------------------------------------------------------------------
    // Transfers (v1: compose the scp command, report it, do NOT spawn)
    // -----------------------------------------------------------------------

    /// The selected local entry, or null when none.
    fn selectedLocal(self: *Self) ?*SarvFile {
        const priv = self.private();
        const idx = priv.local_model.getSelected();
        const object_ = priv.local_model.as(gio.ListModel).getObject(idx) orelse return null;
        // The list store owns a ref; getObject added one we must drop, but the
        // caller only reads immediately, so unref here and rely on the store's.
        defer object_.unref();
        return gobject.ext.cast(SarvFile, object_);
    }

    /// The selected remote entry, or null when none.
    fn selectedRemote(self: *Self) ?*SarvFile {
        const priv = self.private();
        const idx = priv.remote_model.getSelected();
        const object_ = priv.remote_model.as(gio.ListModel).getObject(idx) orelse return null;
        defer object_.unref();
        return gobject.ext.cast(SarvFile, object_);
    }

    fn uploadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const wrapper = self.selectedLocal() orelse {
            self.setStatus("Select a local file to upload.");
            return;
        };
        const name = wrapper.getName() orelse return;

        const host = self.selectedHost() orelse {
            self.setStatus("Pick a real host (not Demo) to transfer.");
            return;
        };

        const local_full = childPath(gpa, priv.local_dir, name) orelse return;
        defer gpa.free(local_full);
        const remote_full = childPath(gpa, priv.remote_dir, name) orelse return;
        defer gpa.free(remote_full);

        // NOTE: v1 only *composes* the command; a real transfer (spawn + async
        // progress + askpass) is a follow-up.
        const cmd = sarv.sftp.scpUpload(gpa, host, local_full, remote_full, wrapper.getIsDir()) catch {
            self.setStatus("Failed to build the upload command.");
            return;
        };
        defer gpa.free(cmd);

        const msg = std.fmt.allocPrintSentinel(gpa, "Would upload {s} → {s}", .{ name, remote_full }, 0) catch return;
        defer gpa.free(msg);
        priv.status_label.setLabel(msg);
    }

    fn downloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const wrapper = self.selectedRemote() orelse {
            self.setStatus("Select a remote file to download.");
            return;
        };
        const name = wrapper.getName() orelse return;

        const host = self.selectedHost() orelse {
            self.setStatus("Pick a real host (not Demo) to transfer.");
            return;
        };

        const remote_full = childPath(gpa, priv.remote_dir, name) orelse return;
        defer gpa.free(remote_full);
        const local_full = childPath(gpa, priv.local_dir, name) orelse return;
        defer gpa.free(local_full);

        // NOTE: v1 only *composes* the command; the real transfer is a follow-up.
        const cmd = sarv.sftp.scpDownload(gpa, host, remote_full, local_full, wrapper.getIsDir()) catch {
            self.setStatus("Failed to build the download command.");
            return;
        };
        defer gpa.free(cmd);

        const msg = std.fmt.allocPrintSentinel(gpa, "Would download {s} → {s}", .{ name, local_full }, 0) catch return;
        defer gpa.free(msg);
        priv.status_label.setLabel(msg);
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
            class.bindTemplateChildPrivate("local_path", .{});
            class.bindTemplateChildPrivate("local_view", .{});
            class.bindTemplateChildPrivate("local_model", .{});
            class.bindTemplateChildPrivate("local_source", .{});
            class.bindTemplateChildPrivate("host_dropdown", .{});
            class.bindTemplateChildPrivate("host_names", .{});
            class.bindTemplateChildPrivate("remote_path", .{});
            class.bindTemplateChildPrivate("remote_view", .{});
            class.bindTemplateChildPrivate("remote_model", .{});
            class.bindTemplateChildPrivate("remote_source", .{});
            class.bindTemplateChildPrivate("status_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("host_changed", &hostChanged);
            class.bindTemplateCallback("local_activated", &localActivated);
            class.bindTemplateCallback("local_up_clicked", &localUpClicked);
            class.bindTemplateCallback("remote_activated", &remoteActivated);
            class.bindTemplateCallback("remote_up_clicked", &remoteUpClicked);
            class.bindTemplateCallback("upload_clicked", &uploadClicked);
            class.bindTemplateCallback("download_clicked", &downloadClicked);

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
