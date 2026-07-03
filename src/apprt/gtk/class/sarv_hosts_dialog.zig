//! The Sarv "Hosts" dialog for the GTK app: lists saved hosts from the
//! cross-platform vault (src/sarv) and opens an SSH session in a new tab on
//! activation. This is the GTK counterpart of the macOS Vaults hosts grid.
//!
//! Password/askpass feeding and host-key pre-flight are follow-ups; this
//! first cut connects key/agent-based hosts (ssh prompts on the TTY if a
//! password is required).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const sarv = @import("../../../sarv/main.zig");
const gresource = @import("../build/gresource.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const SarvHostEditor = @import("sarv_host_editor.zig").SarvHostEditor;

const log = std.log.scoped(.gtk_sarv_hosts_dialog);

pub const SarvHostsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvHostsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The window this dialog opens tabs into.
        window: WeakRef(Window) = .empty,
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        filter_model: *gtk.FilterListModel,
        source: *gio.ListStore,
        empty_label: *gtk.Label,
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
        priv.source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`, (re)loading hosts from the vault.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.reload();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Load hosts + groups from the vault into the list store.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer hosts.deinit();

        var groups = sarv.vault.loadGroups(gpa) catch |err| {
            log.warn("failed to load groups: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer groups.deinit();

        for (hosts.items) |*host| {
            const obj = SarvHost.new(host, groups.items) catch |err| {
                log.warn("failed to wrap host: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }
        self.updateEmpty(hosts.items.len);
    }

    fn updateEmpty(self: *Self, count: usize) void {
        self.private().empty_label.as(gtk.Widget).setVisible(@intFromBool(count == 0));
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        // The FilterListModel is bound to the search text in the blueprint;
        // nothing to do here yet beyond a hook for future behavior.
        _ = self;
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        self.connectAt(pos);
    }

    fn addClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const editor = SarvHostEditor.new();
        defer editor.unref();
        self.connectEditorSaved(editor);
        editor.presentNew(self.private().dialog.as(gtk.Widget));
    }

    fn editClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const object_ = priv.model.as(gio.ListModel).getObject(priv.model.getSelected());
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvHost, object_ orelse return) orelse return;
        const id = wrapper.getId() orelse return;

        // Reload the full host by id so the form has every field, not just the
        // display strings the list wrapper keeps.
        const gpa = Application.default().allocator();
        var hosts = sarv.vault.loadHosts(gpa) catch return;
        defer hosts.deinit();
        const host = for (hosts.items) |*h| {
            if (std.mem.eql(u8, h.id, id)) break h;
        } else return;

        const editor = SarvHostEditor.new();
        defer editor.unref();
        self.connectEditorSaved(editor);
        editor.presentEdit(priv.dialog.as(gtk.Widget), host);
    }

    /// Reload the list whenever the editor reports a successful save/delete.
    fn connectEditorSaved(self: *Self, editor: *SarvHostEditor) void {
        _ = SarvHostEditor.signals.saved.connect(
            editor,
            *Self,
            editorSaved,
            self,
            .{},
        );
    }

    fn editorSaved(_: *SarvHostEditor, self: *Self) callconv(.c) void {
        self.reload();
    }

    /// Open an SSH tab for the host at visible position `pos`.
    fn connectAt(self: *Self, pos: c_uint) void {
        const priv = self.private();

        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvHost, object_ orelse return) orelse return;
        const id = wrapper.getId() orelse return;

        const window = priv.window.get() orelse return;
        defer window.unref();

        const gpa = Application.default().allocator();

        // Reload the full host by id so we have the password and every SSH
        // option, not just the display strings the list wrapper keeps.
        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load host for connect: {}", .{err});
            return;
        };
        defer hosts.deinit();
        const host = for (hosts.items) |*h| {
            if (std.mem.eql(u8, h.id, id)) break h;
        } else return;

        // Build the shell command. When a password is stored, feed it to ssh
        // out-of-band via SSH_ASKPASS (staged connect); otherwise a plain
        // command lets ssh use keys/agent (and prompt on the TTY if needed).
        const cmd_str: []u8 = blk: {
            if (host.password.len > 0) {
                var env = sarv.askpass.prepare(gpa, host.password) catch |err| {
                    log.warn("askpass prepare failed, connecting without password: {}", .{err});
                    break :blk sarv.ssh.command(gpa, host, false) catch return;
                };
                // Free the env strings but keep the password file on disk so
                // ssh can read it. Cleanup on app exit is a follow-up.
                defer env.deinit();
                break :blk sarv.ssh.commandWithEnv(gpa, host, true, env) catch return;
            }
            break :blk sarv.ssh.command(gpa, host, false) catch return;
        };
        defer gpa.free(cmd_str);

        const cmd_z = gpa.dupeZ(u8, cmd_str) catch return;
        defer gpa.free(cmd_z);
        const title_z = gpa.dupeZ(u8, if (host.label.len > 0) host.label else host.hostname) catch null;
        defer if (title_z) |t| gpa.free(t);

        var command: configpkg.Command = undefined;
        command.parseCLI(gpa, cmd_z) catch |err| {
            log.warn("failed to parse ssh command: {}", .{err});
            return;
        };

        window.newTabWithCommand(command, title_z);
        _ = priv.dialog.close();
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
            gobject.ext.ensureType(SarvHost);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-hosts-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("add_clicked", &addClicked);
            class.bindTemplateCallback("edit_clicked", &editClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one saved host for the list model. Holds the
/// display strings and the prebuilt ssh command; all strings live in a
/// per-object arena.
const SarvHost = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvHost",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const label = defineStr("label", propGetLabel);
        pub const subtitle = defineStr("subtitle", propGetSubtitle);
        pub const @"search-text" = defineStr("search-text", propGetSearchText);

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
        id: ?[:0]const u8 = null,
        label: ?[:0]const u8 = null,
        subtitle: ?[:0]const u8 = null,
        search_text: ?[:0]const u8 = null,
        pub var offset: c_int = 0;
    };

    pub fn new(host: *const sarv.model.SavedHost, groups: []const sarv.model.HostGroup) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.id = try alloc.dupeZ(u8, host.id);

        const label = if (host.label.len > 0) host.label else host.hostname;
        priv.label = try alloc.dupeZ(u8, label);

        // subtitle: user@host[:port]
        const user_part = if (host.username.len > 0) host.username else "";
        priv.subtitle = if (user_part.len > 0)
            try std.fmt.allocPrintSentinel(alloc, "{s}@{s}", .{ user_part, host.hostname }, 0)
        else
            try alloc.dupeZ(u8, host.hostname);

        // search text: label + subtitle + group path + tags
        const gpath = try sarv.vault.groupPath(alloc, groups, host.groupID);
        priv.search_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} {s} {s}",
            .{ priv.label.?, priv.subtitle.?, gpath },
            0,
        );

        return self;
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

    pub fn getId(self: *Self) ?[:0]const u8 {
        return self.private().id;
    }

    fn propGetLabel(self: *Self) ?[:0]const u8 {
        return self.private().label;
    }
    fn propGetSubtitle(self: *Self) ?[:0]const u8 {
        return self.private().subtitle;
    }
    fn propGetSearchText(self: *Self) ?[:0]const u8 {
        return self.private().search_text;
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
                properties.@"search-text".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
