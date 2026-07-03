//! The Sarv "Known Hosts" dialog for the GTK app: lists entries parsed from
//! `~/.ssh/known_hosts` (via src/sarv/known_hosts.zig) and lets the user remove
//! the selected entry with `ssh-keygen -R`. This is the GTK counterpart of the
//! macOS Known Hosts manager.
//!
//! Removal is a header-bar action that operates on the current selection (like
//! the hosts dialog's edit button); rows have no inline buttons.

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

const log = std.log.scoped(.gtk_sarv_known_hosts_dialog);

pub const SarvKnownHostsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvKnownHostsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The window this dialog is presented over.
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

    /// Present the dialog over `window`, (re)loading known hosts from disk.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.reload();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Load and parse `~/.ssh/known_hosts` into the list store.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        var loaded = sarv.known_hosts.load(gpa) catch |err| {
            log.warn("failed to load known hosts: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer loaded.deinit();

        for (loaded.entries) |*entry| {
            const obj = SarvKnownHost.new(entry) catch |err| {
                log.warn("failed to wrap known host: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }
        self.updateEmpty(loaded.entries.len);
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

    /// Remove the currently selected known-host entry via `ssh-keygen -R`.
    fn removeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const object_ = priv.model.as(gio.ListModel).getObject(priv.model.getSelected());
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvKnownHost, object_ orelse return) orelse return;
        const token = wrapper.getToken() orelse return;

        const gpa = Application.default().allocator();
        sarv.known_hosts.remove(gpa, token) catch |err| {
            log.warn("failed to remove known host '{s}': {}", .{ token, err });
            return;
        };
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
            gobject.ext.ensureType(SarvKnownHost);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-known-hosts-dialog",
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
            class.bindTemplateCallback("remove_clicked", &removeClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one parsed known-host entry for the list model. Holds
/// the display strings and the raw host token used for removal; all strings
/// live in a per-object arena.
const SarvKnownHost = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvKnownHost",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const host = defineStr("host", propGetHost);
        pub const @"key-type" = defineStr("key-type", propGetKeyType);
        pub const fingerprint = defineStr("fingerprint", propGetFingerprint);
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
        /// The raw host token used for removal via `ssh-keygen -R`.
        token: ?[:0]const u8 = null,
        host: ?[:0]const u8 = null,
        key_type: ?[:0]const u8 = null,
        fingerprint: ?[:0]const u8 = null,
        subtitle: ?[:0]const u8 = null,
        search_text: ?[:0]const u8 = null,
        pub var offset: c_int = 0;
    };

    pub fn new(entry: *const sarv.known_hosts.KnownHostEntry) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        // The host token is what `ssh-keygen -R` matches against for removal.
        priv.token = try alloc.dupeZ(u8, entry.host);
        priv.host = try alloc.dupeZ(u8, entry.host);
        priv.key_type = try alloc.dupeZ(u8, entry.keyType);
        priv.fingerprint = try alloc.dupeZ(u8, entry.fingerprint);

        // subtitle: keyType · fingerprint
        priv.subtitle = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} · {s}",
            .{ entry.keyType, entry.fingerprint },
            0,
        );

        // search text: host + fingerprint
        priv.search_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} {s}",
            .{ entry.host, entry.fingerprint },
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

    pub fn getToken(self: *Self) ?[:0]const u8 {
        return self.private().token;
    }

    fn propGetHost(self: *Self) ?[:0]const u8 {
        return self.private().host;
    }
    fn propGetKeyType(self: *Self) ?[:0]const u8 {
        return self.private().key_type;
    }
    fn propGetFingerprint(self: *Self) ?[:0]const u8 {
        return self.private().fingerprint;
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
                properties.host.impl,
                properties.@"key-type".impl,
                properties.fingerprint.impl,
                properties.subtitle.impl,
                properties.@"search-text".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
