//! Add/edit/delete form for a Sarv saved host in the GTK app. Writes back
//! through the cross-platform vault (src/sarv), so hosts created here are
//! byte-compatible with the macOS app and sync. Emits `saved` after a
//! successful write so the hosts dialog can refresh.
//!
//! This first cut covers the core fields (label, hostname, user, port, auth,
//! identity, password, note). Advanced SSH options and group assignment are
//! follow-ups.

const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const sarv = @import("../../../sarv/main.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;

const log = std.log.scoped(.gtk_sarv_host_editor);

pub const SarvHostEditor = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvHostEditor",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        /// Emitted after a successful save or delete.
        pub const saved = struct {
            pub const name = "saved";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };
    };

    const Private = struct {
        dialog: *adw.Dialog,
        label_row: *adw.EntryRow,
        hostname_row: *adw.EntryRow,
        username_row: *adw.EntryRow,
        port_row: *adw.SpinRow,
        auth_row: *adw.ComboRow,
        identity_row: *adw.EntryRow,
        password_row: *adw.PasswordEntryRow,
        note_row: *adw.EntryRow,
        delete_group: *adw.PreferencesGroup,

        /// Empty for a new host; set to the id being edited otherwise.
        edit_id: ?[]const u8 = null,
        /// Preserved creation timestamp when editing.
        created_at: ?[]const u8 = null,
        /// Owns edit_id/created_at copies.
        arena: std.heap.ArenaAllocator,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().arena = .init(Application.default().allocator());
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    /// Present as a "new host" form over `parent`.
    pub fn presentNew(self: *Self, parent: *gtk.Widget) void {
        const priv = self.private();
        priv.delete_group.as(gtk.Widget).setVisible(0); // no delete for new
        priv.dialog.present(parent);
    }

    /// Present as an "edit" form for `host` over `parent`.
    pub fn presentEdit(self: *Self, parent: *gtk.Widget, host: *const sarv.model.SavedHost) void {
        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.edit_id = alloc.dupe(u8, host.id) catch null;
        priv.created_at = alloc.dupe(u8, host.createdAt) catch null;

        setRow(priv.label_row.as(gtk.Editable), host.label);
        setRow(priv.hostname_row.as(gtk.Editable), host.hostname);
        setRow(priv.username_row.as(gtk.Editable), host.username);
        priv.port_row.as(adw.SpinRow).setValue(@floatFromInt(host.port));
        priv.auth_row.setSelected(authIndex(host.authMethod));
        setRow(priv.identity_row.as(gtk.Editable), host.identityFile);
        setRow(priv.password_row.as(gtk.Editable), host.password);
        setRow(priv.note_row.as(gtk.Editable), host.note);

        priv.delete_group.as(gtk.Widget).setVisible(1);
        priv.dialog.present(parent);
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.private().dialog.close();
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        // A hostname is the one hard requirement.
        const hostname = rowText(priv.hostname_row.as(gtk.Editable));
        if (hostname.len == 0) {
            priv.hostname_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        // Generate an id + timestamps as needed. These live on the stack for
        // the duration of upsertHost, which serializes immediately.
        var id_buf: []u8 = undefined;
        const id: []const u8 = priv.edit_id orelse blk: {
            id_buf = sarv.util.uuidV4(gpa) catch return;
            break :blk id_buf;
        };
        defer if (priv.edit_id == null) gpa.free(id_buf);

        const now = sarv.util.iso8601(gpa, std.time.timestamp()) catch return;
        defer gpa.free(now);

        const host: sarv.model.SavedHost = .{
            .id = id,
            .label = rowText(priv.label_row.as(gtk.Editable)),
            .hostname = hostname,
            .username = rowText(priv.username_row.as(gtk.Editable)),
            .port = @intFromFloat(priv.port_row.as(adw.SpinRow).getValue()),
            .authMethod = authFromIndex(priv.auth_row.getSelected()),
            .identityFile = rowText(priv.identity_row.as(gtk.Editable)),
            .password = rowText(priv.password_row.as(gtk.Editable)),
            .note = rowText(priv.note_row.as(gtk.Editable)),
            .createdAt = priv.created_at orelse now,
            .updatedAt = now,
        };

        sarv.vault.upsertHost(gpa, host) catch |err| {
            log.warn("failed to save host: {}", .{err});
            return;
        };

        signals.saved.impl.emit(self, null, .{}, null);
        _ = priv.dialog.close();
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const id = priv.edit_id orelse return;
        sarv.vault.deleteHost(Application.default().allocator(), id) catch |err| {
            log.warn("failed to delete host: {}", .{err});
            return;
        };
        signals.saved.impl.emit(self, null, .{}, null);
        _ = priv.dialog.close();
    }

    fn setRow(editable: *gtk.Editable, value: []const u8) void {
        const z = Application.default().allocator().dupeZ(u8, value) catch return;
        defer Application.default().allocator().free(z);
        editable.setText(z);
    }

    fn rowText(editable: *gtk.Editable) []const u8 {
        return std.mem.span(editable.getText());
    }

    fn authIndex(method: sarv.model.SavedHost.AuthMethod) c_uint {
        return switch (method) {
            .password => 0,
            .publicKey => 1,
            .agent => 2,
            .ask => 3,
        };
    }

    fn authFromIndex(index: c_uint) sarv.model.SavedHost.AuthMethod {
        return switch (index) {
            0 => .password,
            1 => .publicKey,
            2 => .agent,
            else => .ask,
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-host-editor",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("label_row", .{});
            class.bindTemplateChildPrivate("hostname_row", .{});
            class.bindTemplateChildPrivate("username_row", .{});
            class.bindTemplateChildPrivate("port_row", .{});
            class.bindTemplateChildPrivate("auth_row", .{});
            class.bindTemplateChildPrivate("identity_row", .{});
            class.bindTemplateChildPrivate("password_row", .{});
            class.bindTemplateChildPrivate("note_row", .{});
            class.bindTemplateChildPrivate("delete_group", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("cancel_clicked", &cancelClicked);
            class.bindTemplateCallback("save_clicked", &saveClicked);
            class.bindTemplateCallback("delete_clicked", &deleteClicked);

            signals.saved.impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
