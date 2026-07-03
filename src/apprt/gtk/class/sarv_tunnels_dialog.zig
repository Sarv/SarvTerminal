//! The Sarv "Port Forwarding" dialog for the GTK app: lists saved port-forward
//! rules from the cross-platform vault (src/sarv), resolving each rule's host by
//! its hostID, and starts/stops the corresponding `ssh -N` tunnel on demand.
//! This is the GTK counterpart of the macOS PortForwardManager UI.
//!
//! Running tunnels must outlive the individual list items (rows are recreated on
//! every reload/filter), so they live on the DIALOG's Private in a small map
//! keyed by rule id. On dialog dispose, all running tunnels are stopped.

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

const Tunnel = sarv.portforward.Tunnel;

const log = std.log.scoped(.gtk_sarv_tunnels_dialog);

pub const SarvTunnelsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvTunnelsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// A live tunnel entry owned by the dialog: the running Tunnel plus the
    /// `ssh -N …` command string it borrows (Tunnel does not free it). Both are
    /// allocated with the app allocator so they outlive the list items.
    const Running = struct {
        tunnel: *Tunnel,
        command: []u8,
    };

    const Private = struct {
        /// The window this dialog belongs to.
        window: WeakRef(Window) = .empty,
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        filter_model: *gtk.FilterListModel,
        source: *gio.ListStore,
        empty_label: *gtk.Label,

        /// Running tunnels keyed by rule id. Keys and the Running payloads are
        /// all allocated with the app allocator and freed in stopTunnel/dispose.
        running: std.StringHashMapUnmanaged(Running) = .empty,

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

        // Stop and free every running tunnel before we go away.
        const gpa = Application.default().allocator();
        var it = priv.running.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.tunnel.stop();
            gpa.destroy(entry.value_ptr.tunnel);
            gpa.free(entry.value_ptr.command);
            gpa.free(entry.key_ptr.*);
        }
        priv.running.deinit(gpa);

        priv.source.removeAll();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// Present the dialog over `window`, (re)loading rules from the vault.
    pub fn present(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.window.set(window);
        self.reload();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Load port-forward rules + hosts from the vault into the list store.
    fn reload(self: *Self) void {
        const priv = self.private();
        priv.source.removeAll();

        const gpa = Application.default().allocator();

        var rules = sarv.vault.loadPortForwards(gpa) catch |err| {
            log.warn("failed to load port forwards: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer rules.deinit();

        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            self.updateEmpty(0);
            return;
        };
        defer hosts.deinit();

        for (rules.items) |*rule| {
            const host = findHost(hosts.items, rule.hostID);
            const is_running = priv.running.contains(rule.id);
            const obj = SarvTunnel.new(rule, host, is_running) catch |err| {
                log.warn("failed to wrap port forward: {}", .{err});
                continue;
            };
            defer obj.unref();
            priv.source.append(obj.as(gobject.Object));
        }
        self.updateEmpty(rules.items.len);
    }

    fn findHost(hosts: []const sarv.model.SavedHost, id: []const u8) ?*const sarv.model.SavedHost {
        for (hosts) |*h| {
            if (std.mem.eql(u8, h.id, id)) return h;
        }
        return null;
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
        self.toggleAt(pos);
    }

    fn toggleClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.toggleAt(self.private().model.getSelected());
    }

    /// Start (or stop, if already running) the tunnel for the rule at visible
    /// position `pos`.
    fn toggleAt(self: *Self, pos: c_uint) void {
        const priv = self.private();

        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |o| o.unref();
        const wrapper = gobject.ext.cast(SarvTunnel, object_ orelse return) orelse return;
        const id = wrapper.getId() orelse return;

        if (priv.running.contains(id)) {
            self.stopTunnel(id);
        } else {
            self.startTunnel(id);
        }

        // Refresh the list so the running state reflected in each row updates.
        self.reload();
    }

    /// Build the tunnel command for rule `id`, spawn it, and record it.
    fn startTunnel(self: *Self, id: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        // Reload the rule + its host by id so we build the command from the
        // full records, not just the display strings the list wrapper keeps.
        var rules = sarv.vault.loadPortForwards(gpa) catch |err| {
            log.warn("failed to load port forwards for start: {}", .{err});
            return;
        };
        defer rules.deinit();
        const rule = for (rules.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) break r;
        } else return;

        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts for start: {}", .{err});
            return;
        };
        defer hosts.deinit();
        const host = findHost(hosts.items, rule.hostID) orelse {
            log.warn("port forward references unknown host: {s}", .{rule.hostID});
            return;
        };

        // The command string must outlive the loaded stores and the Tunnel, so
        // it is owned by the app allocator (Tunnel borrows it, never frees it).
        const command = sarv.portforward.tunnelCommand(gpa, rule.*, host.*) catch |err| {
            log.warn("failed to build tunnel command: {}", .{err});
            return;
        };
        errdefer gpa.free(command);

        const tunnel = gpa.create(Tunnel) catch return;
        errdefer gpa.destroy(tunnel);
        tunnel.* = Tunnel.init(command);
        tunnel.start(gpa) catch |err| {
            log.warn("failed to start tunnel: {}", .{err});
            return;
        };
        errdefer tunnel.stop();

        // Own a copy of the id as the map key so it survives the store deinit.
        const key = gpa.dupe(u8, id) catch {
            tunnel.stop();
            gpa.destroy(tunnel);
            gpa.free(command);
            return;
        };
        priv.running.put(gpa, key, .{ .tunnel = tunnel, .command = command }) catch {
            gpa.free(key);
            tunnel.stop();
            gpa.destroy(tunnel);
            gpa.free(command);
            return;
        };
    }

    /// Stop and remove the running tunnel for rule `id`, if any.
    fn stopTunnel(self: *Self, id: []const u8) void {
        const priv = self.private();
        const gpa = Application.default().allocator();

        const entry = priv.running.fetchRemove(id) orelse return;
        entry.value.tunnel.stop();
        gpa.destroy(entry.value.tunnel);
        gpa.free(entry.value.command);
        gpa.free(entry.key);
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
            gobject.ext.ensureType(SarvTunnel);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sarv-tunnels-dialog",
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
            class.bindTemplateCallback("toggle_clicked", &toggleClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// GObject wrapper around one port-forward rule for the list model. Holds the
/// display strings and the rule id; all strings live in a per-object arena.
const SarvTunnel = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvTunnel",
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

    pub fn new(
        pf: *const sarv.model.PortForward,
        host: ?*const sarv.model.SavedHost,
        is_running: bool,
    ) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.id = try alloc.dupeZ(u8, pf.id);

        const name = if (pf.name.len > 0) pf.name else "Tunnel";
        priv.label = try alloc.dupeZ(u8, name);

        // The host label for the "via <host>" suffix.
        const host_label: []const u8 = if (host) |h|
            (if (h.label.len > 0) h.label else h.hostname)
        else
            "unknown host";

        // Kind label and forward spec mirror the macOS subtitle.
        const kind_label = switch (pf.kind) {
            .local => "Local -L",
            .remote => "Remote -R",
            .dynamic => "Dynamic -D",
        };

        const status = if (is_running) "running · " else "";

        priv.subtitle = switch (pf.kind) {
            .dynamic => try std.fmt.allocPrintSentinel(
                alloc,
                "{s}{s} · {s}:{d} · via {s}",
                .{ status, kind_label, pf.bindAddress, pf.listenPort, host_label },
                0,
            ),
            .local, .remote => try std.fmt.allocPrintSentinel(
                alloc,
                "{s}{s} · {s}:{d}→{s}:{d} · via {s}",
                .{
                    status,
                    kind_label,
                    pf.bindAddress,
                    pf.listenPort,
                    pf.destinationHost,
                    pf.destinationPort,
                    host_label,
                },
                0,
            ),
        };

        priv.search_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{s} {s}",
            .{ priv.label.?, priv.subtitle.? },
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
