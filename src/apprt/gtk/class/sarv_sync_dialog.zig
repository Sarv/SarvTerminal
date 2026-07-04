//! Encrypted-sync settings dialog for the GTK app: a single form over a folder
//! backend (a local or cloud-synced directory). Reads the local vault
//! (src/sarv) and pushes it as an encrypted payload, or pulls a payload and
//! writes it back to the vault — byte-compatible with the macOS app.
//!
//! The folder path can point at any synced directory (iCloud Drive, Dropbox, a
//! git checkout, …); the crypto + protocol live in src/sarv/sync.zig, so this
//! class is just the form + wiring.

const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const sarv = @import("../../../sarv/main.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_sarv_sync_dialog);

pub const SarvSyncDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvSyncDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        dialog: *adw.Dialog,
        folder_row: *adw.EntryRow,
        device_row: *adw.EntryRow,
        password_row: *adw.PasswordEntryRow,
        push_button: *gtk.Button,
        pull_button: *gtk.Button,
        status_label: *gtk.Label,

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
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`, refreshing the folder status first.
    pub fn present(self: *Self, window: *Window) void {
        self.refreshStatus();
        self.private().dialog.present(window.as(gtk.Widget));
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    /// Read the plaintext manifest (no password) and describe the remote state.
    fn refreshStatus(self: *Self) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const dir = rowText(priv.folder_row.as(gtk.Editable));
        if (dir.len == 0) {
            self.setStatus("Choose a sync folder to see its status.");
            return;
        }

        var st_ = sarv.sync.status(gpa, dir) catch |err| {
            log.warn("failed to read sync status: {}", .{err});
            self.setStatus("Could not read sync status for this folder.");
            return;
        };
        if (st_) |*st| {
            defer st.deinit();
            const msg = std.fmt.allocPrint(
                gpa,
                "Version {d} · last pushed from {s} · {s}",
                .{ st.version, st.device_name, st.last_sync_date },
            ) catch return;
            defer gpa.free(msg);
            self.setStatus(msg);
        } else {
            self.setStatus("No sync data in this folder yet.");
        }
    }

    fn pushClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        priv.folder_row.as(gtk.Widget).removeCssClass("error");
        priv.password_row.as(gtk.Widget).removeCssClass("error");

        const dir = rowText(priv.folder_row.as(gtk.Editable));
        const password = rowText(priv.password_row.as(gtk.Editable));
        const device = rowText(priv.device_row.as(gtk.Editable));

        if (dir.len == 0) {
            priv.folder_row.as(gtk.Widget).addCssClass("error");
            return;
        }
        if (password.len == 0) {
            priv.password_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts for push: {}", .{err});
            self.setStatus("Could not read local hosts.");
            return;
        };
        defer hosts.deinit();

        var groups = sarv.vault.loadGroups(gpa) catch |err| {
            log.warn("failed to load groups for push: {}", .{err});
            self.setStatus("Could not read local groups.");
            return;
        };
        defer groups.deinit();

        var snippets = sarv.vault.loadSnippets(gpa) catch |err| {
            log.warn("failed to load snippets for push: {}", .{err});
            self.setStatus("Could not read local snippets.");
            return;
        };
        defer snippets.deinit();

        const now = sarv.util.iso8601(gpa, std.time.timestamp()) catch return;
        defer gpa.free(now);

        const data: sarv.sync.PushData = .{
            .dir = dir,
            .password = password,
            .device_name = device,
            .now_iso = now,
            .hosts = hosts.items,
            .groups = groups.items,
            .snippets = snippets.items,
        };

        const version = sarv.sync.push(gpa, data) catch |err| {
            switch (err) {
                sarv.sync.Error.WrongPassword => self.setStatus("Wrong master password."),
                else => {
                    log.warn("push failed: {}", .{err});
                    self.setStatus("Push failed. Check the folder and try again.");
                },
            }
            return;
        };

        const msg = std.fmt.allocPrint(gpa, "Pushed v{d}.", .{version}) catch return;
        defer gpa.free(msg);
        self.setStatus(msg);
        self.refreshStatus();
    }

    fn pullClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        priv.folder_row.as(gtk.Widget).removeCssClass("error");
        priv.password_row.as(gtk.Widget).removeCssClass("error");

        const dir = rowText(priv.folder_row.as(gtk.Editable));
        const password = rowText(priv.password_row.as(gtk.Editable));

        if (dir.len == 0) {
            priv.folder_row.as(gtk.Widget).addCssClass("error");
            return;
        }
        if (password.len == 0) {
            priv.password_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        var pulled = sarv.sync.pull(gpa, dir, password) catch |err| {
            switch (err) {
                sarv.sync.Error.WrongPassword => self.setStatus("Wrong master password."),
                sarv.sync.Error.NoManifest => self.setStatus("No sync data in this folder yet."),
                else => {
                    log.warn("pull failed: {}", .{err});
                    self.setStatus("Pull failed. Check the folder and try again.");
                },
            }
            return;
        };
        defer pulled.deinit();

        sarv.vault.saveHosts(gpa, pulled.hosts) catch |err| {
            log.warn("failed to save pulled hosts: {}", .{err});
            self.setStatus("Pulled, but could not write hosts locally.");
            return;
        };
        sarv.vault.saveGroups(gpa, pulled.groups) catch |err| {
            log.warn("failed to save pulled groups: {}", .{err});
            self.setStatus("Pulled, but could not write groups locally.");
            return;
        };
        if (pulled.snippets) |snippets| {
            sarv.vault.saveSnippets(gpa, snippets) catch |err| {
                log.warn("failed to save pulled snippets: {}", .{err});
                self.setStatus("Pulled, but could not write snippets locally.");
                return;
            };
        }

        const msg = std.fmt.allocPrint(
            gpa,
            "Pulled v{d} — {d} hosts.",
            .{ pulled.version, pulled.hosts.len },
        ) catch return;
        defer gpa.free(msg);
        self.setStatus(msg);
    }

    /// Set the status label from a (non-null-terminated) slice.
    fn setStatus(self: *Self, text: []const u8) void {
        const gpa = Application.default().allocator();
        const z = gpa.dupeZ(u8, text) catch return;
        defer gpa.free(z);
        self.private().status_label.setText(z);
    }

    fn rowText(editable: *gtk.Editable) []const u8 {
        return std.mem.span(editable.getText());
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
                    .name = "sarv-sync-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("folder_row", .{});
            class.bindTemplateChildPrivate("device_row", .{});
            class.bindTemplateChildPrivate("password_row", .{});
            class.bindTemplateChildPrivate("push_button", .{});
            class.bindTemplateChildPrivate("pull_button", .{});
            class.bindTemplateChildPrivate("status_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("push_clicked", &pushClicked);
            class.bindTemplateCallback("pull_clicked", &pullClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
