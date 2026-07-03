//! The Sarv "SSH Keychain" dialog for the GTK app: lists SSH keys discovered
//! in `~/.ssh` (see src/sarv/sshkeys.zig), and lets the user generate a new
//! key pair or delete an existing one. This is the GTK counterpart of the
//! macOS SSH key manager.
//!
//! The list is built by scanning the directory (the files on disk are the
//! source of truth). Generation shells out to `ssh-keygen` through
//! `sarv.sshkeys.generate`; deletion removes the private/public pair.

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

const log = std.log.scoped(.gtk_sarv_keys_dialog);

pub const SarvKeysDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvKeysDialog",
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

        // The inline "generate key" form (a second top-level dialog in the
        // same blueprint).
        generate_dialog: *adw.Dialog,
        name_row: *adw.EntryRow,
        type_row: *adw.ComboRow,
        comment_row: *adw.EntryRow,
        passphrase_row: *adw.PasswordEntryRow,

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

    /// Present the dialog over `window`, (re)loading keys from `~/.ssh`.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.reload();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Load keys from `~/.ssh` into the list store.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        var loaded = sarv.sshkeys.list(gpa) catch |err| {
            log.warn("failed to load ssh keys: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer loaded.deinit();

        for (loaded.keys) |*key| {
            const obj = SarvKey.new(key) catch |err| {
                log.warn("failed to wrap ssh key: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }
        self.updateEmpty(loaded.keys.len);
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

    /// Open the inline "generate key" form over the list dialog.
    fn addClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        resetGenerateForm(priv);
        priv.generate_dialog.present(priv.dialog.as(gtk.Widget));
        _ = priv.name_row.as(gtk.Widget).grabFocus();
    }

    /// Clear the generate form fields to their defaults.
    fn resetGenerateForm(priv: *Private) void {
        setRow(priv.name_row.as(gtk.Editable), "");
        setRow(priv.comment_row.as(gtk.Editable), "");
        setRow(priv.passphrase_row.as(gtk.Editable), "");
        priv.type_row.setSelected(0);
        priv.name_row.as(gtk.Widget).removeCssClass("error");
    }

    fn generateCancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.private().generate_dialog.close();
    }

    fn generateConfirmClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const name = rowText(priv.name_row.as(gtk.Editable));
        if (name.len == 0) {
            priv.name_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        // path = ~/.ssh/<name>
        const dir = sarv.sshkeys.sshDir(gpa) catch |err| {
            log.warn("failed to resolve ssh dir: {}", .{err});
            return;
        };
        defer gpa.free(dir);
        const path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
        defer gpa.free(path);

        // Mirror the macOS defaults for the per-type bit sizes.
        const key_type = typeFromIndex(priv.type_row.getSelected());
        const bits: ?u32 = switch (key_type) {
            .rsa => 4096,
            .ecdsa => 521,
            .ed25519 => null,
        };

        const ok = sarv.sshkeys.generate(gpa, .{
            .type = key_type,
            .bits = bits,
            .path = path,
            .passphrase = rowText(priv.passphrase_row.as(gtk.Editable)),
            .comment = rowText(priv.comment_row.as(gtk.Editable)),
        }) catch |err| {
            log.warn("failed to generate ssh key: {}", .{err});
            priv.name_row.as(gtk.Widget).addCssClass("error");
            return;
        };
        if (!ok) {
            // ssh-keygen refused (e.g. the file already exists).
            priv.name_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        _ = priv.generate_dialog.close();
        self.reload();
    }

    /// Delete the selected key's private/public files, then reload.
    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const object_ = priv.model.as(gio.ListModel).getObject(priv.model.getSelected());
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvKey, object_ orelse return) orelse return;
        const path = wrapper.getPath() orelse return;

        sarv.sshkeys.delete(Application.default().allocator(), path) catch |err| {
            log.warn("failed to delete ssh key: {}", .{err});
            return;
        };
        self.reload();
    }

    fn setRow(editable: *gtk.Editable, value: []const u8) void {
        const z = Application.default().allocator().dupeZ(u8, value) catch return;
        defer Application.default().allocator().free(z);
        editable.setText(z);
    }

    fn rowText(editable: *gtk.Editable) []const u8 {
        return std.mem.span(editable.getText());
    }

    fn typeFromIndex(index: c_uint) sarv.sshkeys.KeyType {
        return switch (index) {
            0 => .ed25519,
            1 => .ecdsa,
            else => .rsa,
        };
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
            gobject.ext.ensureType(SarvKey);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-keys-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateChildPrivate("empty_label", .{});
            class.bindTemplateChildPrivate("generate_dialog", .{});
            class.bindTemplateChildPrivate("name_row", .{});
            class.bindTemplateChildPrivate("type_row", .{});
            class.bindTemplateChildPrivate("comment_row", .{});
            class.bindTemplateChildPrivate("passphrase_row", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("add_clicked", &addClicked);
            class.bindTemplateCallback("delete_clicked", &deleteClicked);
            class.bindTemplateCallback("generate_cancel_clicked", &generateCancelClicked);
            class.bindTemplateCallback("generate_confirm_clicked", &generateConfirmClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one discovered SSH key for the list model. Holds the
/// display strings and the on-disk private-key path; all strings live in a
/// per-object arena.
const SarvKey = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvKey",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const name = defineStr("name", propGetName);
        pub const detail = defineStr("detail", propGetDetail);
        pub const fingerprint = defineStr("fingerprint", propGetFingerprint);
        pub const @"search-text" = defineStr("search-text", propGetSearchText);

        fn defineStr(
            comptime name_: [:0]const u8,
            comptime getter: fn (*Self) ?[:0]const u8,
        ) type {
            return struct {
                pub const impl = gobject.ext.defineProperty(name_, Self, ?[:0]const u8, .{
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
        path: ?[:0]const u8 = null,
        name: ?[:0]const u8 = null,
        detail: ?[:0]const u8 = null,
        fingerprint: ?[:0]const u8 = null,
        search_text: ?[:0]const u8 = null,
        pub var offset: c_int = 0;
    };

    pub fn new(key: *const sarv.sshkeys.KeyInfo) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.path = try alloc.dupeZ(u8, key.path);
        priv.name = try alloc.dupeZ(u8, key.name);
        priv.fingerprint = try alloc.dupeZ(u8, key.fingerprint);

        // detail: "TYPE · N bits · comment" (comment dropped when empty).
        priv.detail = if (key.comment.len > 0)
            try std.fmt.allocPrintSentinel(
                alloc,
                "{s} · {d} bits · {s}",
                .{ key.keyType, key.bits, key.comment },
                0,
            )
        else
            try std.fmt.allocPrintSentinel(
                alloc,
                "{s} · {d} bits",
                .{ key.keyType, key.bits },
                0,
            );

        // search text: name + detail + fingerprint.
        priv.search_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} {s} {s}",
            .{ priv.name.?, priv.detail.?, priv.fingerprint.? },
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

    pub fn getPath(self: *Self) ?[:0]const u8 {
        return self.private().path;
    }

    fn propGetName(self: *Self) ?[:0]const u8 {
        return self.private().name;
    }
    fn propGetDetail(self: *Self) ?[:0]const u8 {
        return self.private().detail;
    }
    fn propGetFingerprint(self: *Self) ?[:0]const u8 {
        return self.private().fingerprint;
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
                properties.name.impl,
                properties.detail.impl,
                properties.fingerprint.impl,
                properties.@"search-text".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
