//! The Sarv "Snippets" dialog for the GTK app: a library of saved commands
//! from the cross-platform vault (src/sarv). Activating a row copies the
//! snippet's command to the clipboard; an editor sub-dialog adds, edits and
//! deletes snippets, writing back byte-compatibly with the macOS app and sync.
//!
//! Running a snippet into the focused terminal is a follow-up; this first cut
//! only copies to the clipboard.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const sarv = @import("../../../sarv/main.zig");
const gresource = @import("../build/gresource.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_sarv_snippets_dialog);

pub const SarvSnippetsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvSnippetsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The window this dialog belongs to (used to anchor the editor).
        window: WeakRef(Window) = .empty,
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        filter_model: *gtk.FilterListModel,
        source: *gio.ListStore,
        empty_label: *gtk.Label,

        // Editor sub-dialog and its fields.
        editor: *adw.Dialog,
        name_row: *adw.EntryRow,
        pinned_row: *adw.SwitchRow,
        command_view: *gtk.TextView,
        delete_group: *adw.PreferencesGroup,

        /// Empty for a new snippet; set to the id being edited otherwise.
        edit_id: ?[]const u8 = null,
        /// Preserved creation timestamp when editing.
        created_at: ?[]const u8 = null,
        /// Owns edit_id/created_at copies.
        arena: ArenaAllocator,

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
        const priv = self.private();
        priv.source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`, (re)loading snippets from the vault.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.reload();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Load snippets from the vault into the list store, pinned-first then by
    /// name.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        var snippets = sarv.vault.loadSnippets(gpa) catch |err| {
            log.warn("failed to load snippets: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer snippets.deinit();

        // Sort the slice in place before wrapping: pinned first, then by name.
        std.mem.sort(sarv.model.Snippet, snippets.items, {}, lessThan);

        for (snippets.items) |*snippet| {
            const obj = SarvSnippet.new(snippet) catch |err| {
                log.warn("failed to wrap snippet: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }
        self.updateEmpty(snippets.items.len);
    }

    /// Pinned snippets sort ahead of unpinned; ties break case-insensitively
    /// by name.
    fn lessThan(_: void, a: sarv.model.Snippet, b: sarv.model.Snippet) bool {
        if (a.pinned != b.pinned) return a.pinned;
        return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
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

    /// Copy the activated snippet's command to the clipboard.
    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = self.private();

        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvSnippet, object_ orelse return) orelse return;
        const cmd = wrapper.getCommand() orelse return;

        const clipboard = priv.dialog.as(gtk.Widget).getClipboard();
        clipboard.setText(cmd);
    }

    fn addClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.presentEditorNew();
    }

    fn editClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const object_ = priv.model.as(gio.ListModel).getObject(priv.model.getSelected());
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvSnippet, object_ orelse return) orelse return;
        const id = wrapper.getId() orelse return;

        // Reload the full snippet by id so the form has every field.
        const gpa = Application.default().allocator();
        var snippets = sarv.vault.loadSnippets(gpa) catch return;
        defer snippets.deinit();
        const snippet = for (snippets.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) break s;
        } else return;

        self.presentEditorEdit(snippet);
    }

    // -- Editor sub-dialog -------------------------------------------------

    /// Present the editor as a "new snippet" form.
    fn presentEditorNew(self: *Self) void {
        const priv = self.private();
        priv.edit_id = null;
        priv.created_at = null;

        setEditable(priv.name_row.as(gtk.Editable), "");
        priv.pinned_row.as(adw.SwitchRow).setActive(0);
        setCommand(priv.command_view, "");

        priv.delete_group.as(gtk.Widget).setVisible(0); // no delete for new
        priv.editor.present(priv.dialog.as(gtk.Widget));
    }

    /// Present the editor as an "edit" form for `snippet`.
    fn presentEditorEdit(self: *Self, snippet: *const sarv.model.Snippet) void {
        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.edit_id = alloc.dupe(u8, snippet.id) catch null;
        priv.created_at = alloc.dupe(u8, snippet.createdAt) catch null;

        setEditable(priv.name_row.as(gtk.Editable), snippet.name);
        priv.pinned_row.as(adw.SwitchRow).setActive(@intFromBool(snippet.pinned));
        setCommand(priv.command_view, snippet.command);

        priv.delete_group.as(gtk.Widget).setVisible(1);
        priv.editor.present(priv.dialog.as(gtk.Widget));
    }

    fn editorClosed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        // The editor is a template child owned by this dialog, so closing it
        // must not unref self. Nothing to do here.
        _ = self;
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.private().editor.close();
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        // A name is the one hard requirement.
        const name = editableText(priv.name_row.as(gtk.Editable));
        if (name.len == 0) {
            priv.name_row.as(gtk.Widget).addCssClass("error");
            return;
        }

        const command = commandText(gpa, priv.command_view) catch return;
        defer gpa.free(command);

        // Generate an id + timestamps as needed. These live on the stack for
        // the duration of upsert, which serializes immediately.
        var id_buf: []u8 = undefined;
        const id: []const u8 = priv.edit_id orelse blk: {
            id_buf = sarv.util.uuidV4(gpa) catch return;
            break :blk id_buf;
        };
        defer if (priv.edit_id == null) gpa.free(id_buf);

        const now = sarv.util.iso8601(gpa, std.time.timestamp()) catch return;
        defer gpa.free(now);

        const snippet: sarv.model.Snippet = .{
            .id = id,
            .name = name,
            .command = command,
            .pinned = priv.pinned_row.as(adw.SwitchRow).getActive() != 0,
            .createdAt = priv.created_at orelse now,
            .updatedAt = now,
        };

        upsertSnippet(gpa, snippet) catch |err| {
            log.warn("failed to save snippet: {}", .{err});
            return;
        };

        self.reload();
        _ = priv.editor.close();
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const id = priv.edit_id orelse return;
        deleteSnippet(Application.default().allocator(), id) catch |err| {
            log.warn("failed to delete snippet: {}", .{err});
            return;
        };
        self.reload();
        _ = priv.editor.close();
    }

    // -- Persistence helpers -----------------------------------------------
    //
    // vault.zig has loadSnippets but no save/upsert, so we mirror its
    // saveHosts/upsertHost pattern here against the generic snippet store.

    fn saveSnippets(gpa: Allocator, snippets: []const sarv.model.Snippet) !void {
        const SnippetStore = sarv.store.Store(sarv.model.Snippet);
        const path = try sarv.paths.dataFile(gpa, sarv.vault.snippets_file);
        defer gpa.free(path);
        const key = try sarv.keys.getOrCreate(gpa);
        try SnippetStore.save(gpa, path, snippets, key);
    }

    fn upsertSnippet(gpa: Allocator, snippet: sarv.model.Snippet) !void {
        var loaded = try sarv.vault.loadSnippets(gpa);
        defer loaded.deinit();

        var list: std.ArrayList(sarv.model.Snippet) = .empty;
        defer list.deinit(gpa);

        var replaced = false;
        for (loaded.items) |existing| {
            if (std.mem.eql(u8, existing.id, snippet.id)) {
                var updated = snippet;
                updated.createdAt = existing.createdAt; // keep original creation time
                try list.append(gpa, updated);
                replaced = true;
            } else {
                try list.append(gpa, existing);
            }
        }
        if (!replaced) try list.append(gpa, snippet);

        try saveSnippets(gpa, list.items);
    }

    fn deleteSnippet(gpa: Allocator, id: []const u8) !void {
        var loaded = try sarv.vault.loadSnippets(gpa);
        defer loaded.deinit();

        var list: std.ArrayList(sarv.model.Snippet) = .empty;
        defer list.deinit(gpa);
        for (loaded.items) |existing| {
            if (!std.mem.eql(u8, existing.id, id)) try list.append(gpa, existing);
        }
        try saveSnippets(gpa, list.items);
    }

    // -- Field helpers -----------------------------------------------------

    fn setEditable(editable: *gtk.Editable, value: []const u8) void {
        const gpa = Application.default().allocator();
        const z = gpa.dupeZ(u8, value) catch return;
        defer gpa.free(z);
        editable.setText(z);
    }

    fn editableText(editable: *gtk.Editable) []const u8 {
        return std.mem.span(editable.getText());
    }

    fn setCommand(view: *gtk.TextView, value: []const u8) void {
        const gpa = Application.default().allocator();
        const z = gpa.dupeZ(u8, value) catch return;
        defer gpa.free(z);
        view.getBuffer().setText(z, -1);
    }

    /// Read the full command text out of the TextView's buffer. Caller owns
    /// the returned (sentinel-terminated) slice.
    fn commandText(gpa: Allocator, view: *gtk.TextView) ![:0]const u8 {
        const buffer = view.getBuffer();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        const text = buffer.getText(&start, &end, 0); // exclude hidden chars
        defer glib.free(@ptrCast(text));
        return gpa.dupeZ(u8, std.mem.span(text));
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
            gobject.ext.ensureType(SarvSnippet);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-snippets-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateChildPrivate("editor", .{});
            class.bindTemplateChildPrivate("name_row", .{});
            class.bindTemplateChildPrivate("pinned_row", .{});
            class.bindTemplateChildPrivate("command_view", .{});
            class.bindTemplateChildPrivate("delete_group", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("add_clicked", &addClicked);
            class.bindTemplateCallback("edit_clicked", &editClicked);

            class.bindTemplateCallback("editor_closed", &editorClosed);
            class.bindTemplateCallback("cancel_clicked", &cancelClicked);
            class.bindTemplateCallback("save_clicked", &saveClicked);
            class.bindTemplateCallback("delete_clicked", &deleteClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one saved snippet for the list model. Holds the
/// display strings; all strings live in a per-object arena.
const SarvSnippet = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvSnippet",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const name = defineStr("name", propGetName);
        pub const command = defineStr("command", propGetCommand);
        pub const @"search-text" = defineStr("search-text", propGetSearchText);
        pub const pinned = struct {
            pub const impl = gobject.ext.defineProperty("pinned", Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(Self, bool, .{
                    .getter = propGetPinned,
                }),
            });
        };

        fn defineStr(
            comptime prop_name: [:0]const u8,
            comptime getter: fn (*Self) ?[:0]const u8,
        ) type {
            return struct {
                pub const impl = gobject.ext.defineProperty(prop_name, Self, ?[:0]const u8, .{
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
        name: ?[:0]const u8 = null,
        command: ?[:0]const u8 = null,
        search_text: ?[:0]const u8 = null,
        pinned: bool = false,
        pub var offset: c_int = 0;
    };

    pub fn new(snippet: *const sarv.model.Snippet) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.id = try alloc.dupeZ(u8, snippet.id);
        priv.name = try alloc.dupeZ(u8, snippet.name);
        priv.command = try alloc.dupeZ(u8, snippet.command);
        priv.pinned = snippet.pinned;

        // search text: name + command
        priv.search_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} {s}",
            .{ snippet.name, snippet.command },
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

    pub fn getCommand(self: *Self) ?[:0]const u8 {
        return self.private().command;
    }

    fn propGetName(self: *Self) ?[:0]const u8 {
        return self.private().name;
    }
    fn propGetCommand(self: *Self) ?[:0]const u8 {
        return self.private().command;
    }
    fn propGetSearchText(self: *Self) ?[:0]const u8 {
        return self.private().search_text;
    }
    fn propGetPinned(self: *Self) bool {
        return self.private().pinned;
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
                properties.command.impl,
                properties.@"search-text".impl,
                properties.pinned.impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
