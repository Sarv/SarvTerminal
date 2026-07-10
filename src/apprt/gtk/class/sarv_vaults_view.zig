//! The Sarv "Vaults" view for the GTK app: the macOS main-window layout,
//! embedded in the window as a mode the user toggles into (not a dialog) —
//! a navigation sidebar (Hosts, Keychain, Port Forwarding, Snippets, Known
//! Hosts), a quick-connect search bar and a card grid of groups and hosts.
//! Activating a host card opens an SSH session in a new tab and switches the
//! window back to the terminal.
//!
//! The Hosts page is native to this view; the other sidebar sections open
//! their existing dialogs until they are ported into pages here.

const std = @import("std");
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
const SarvKeysDialog = @import("sarv_keys_dialog.zig").SarvKeysDialog;
const SarvTunnelsDialog = @import("sarv_tunnels_dialog.zig").SarvTunnelsDialog;
const SarvSnippetsDialog = @import("sarv_snippets_dialog.zig").SarvSnippetsDialog;
const SarvKnownHostsDialog = @import("sarv_known_hosts_dialog.zig").SarvKnownHostsDialog;
const SarvFilesDialog = @import("sarv_files_dialog.zig").SarvFilesDialog;
const SarvSyncDialog = @import("sarv_sync_dialog.zig").SarvSyncDialog;

const log = std.log.scoped(.gtk_sarv_vaults_view);

/// Sidebar row order; must match the ListBoxRow order in the blueprint.
const Section = enum(c_int) {
    hosts = 0,
    keychain = 1,
    port_forwarding = 2,
    snippets = 3,
    known_hosts = 4,
};

pub const SarvVaultsView = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySarvVaultsView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// One host card in the grid: the id/search text needed to filter and
    /// connect. Strings live in the reload arena.
    const Card = struct {
        id: [:0]const u8,
        search: []const u8,
        /// The host's group id plus every ancestor group id (leaf → root),
        /// so an active group filter also matches hosts in its subgroups.
        group_chain: []const []const u8,
        child: *gtk.FlowBoxChild,
    };

    /// One group card: the group id it filters by.
    const GroupCard = struct {
        id: [:0]const u8,
        child: *gtk.FlowBoxChild,
    };

    const Private = struct {
        /// The window this view opens tabs into.
        window: WeakRef(Window) = .empty,
        root: *gtk.Box,
        sidebar: *gtk.ListBox,
        search: *gtk.SearchEntry,
        groups_flow: *gtk.FlowBox,
        hosts_flow: *gtk.FlowBox,
        groups_header: *gtk.Label,
        hosts_header: *gtk.Label,
        empty_label: *gtk.Label,

        /// Backing store for the current card grid; reset on every reload.
        arena: ?ArenaAllocator = null,
        cards: std.ArrayListUnmanaged(Card) = .empty,
        group_cards: std.ArrayListUnmanaged(GroupCard) = .empty,

        /// When set, only hosts in this group are shown (a group card is
        /// active). Points into the reload arena.
        active_group: ?[]const u8 = null,

        /// Guards sidebar_selected so programmatic re-selection (bouncing
        /// back to Hosts after opening a section dialog) doesn't recurse.
        reselecting: bool = false,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        // The template root is a free-floating top-level object; adopt it
        // as this Bin's child so the view renders wherever it is placed.
        self.as(adw.Bin).setChild(self.private().root.as(gtk.Widget));
    }

    /// Set the window this view opens tabs into. Called once by the window
    /// after its template initializes.
    pub fn setWindow(self: *Self, window: *Window) void {
        self.private().window.set(window);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.clearGrid();
        if (priv.arena) |*arena| {
            arena.deinit();
            priv.arena = null;
        }
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    /// (Re)load the vault and reset the view; called each time the window
    /// switches into Vaults mode.
    pub fn refresh(self: *Self) void {
        const priv = self.private();
        self.reload();
        self.selectHostsRow();
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Remove every card from both flow boxes. The card slice itself is
    /// owned by the arena and freed on the next reload/dispose.
    fn clearGrid(self: *Self) void {
        const priv = self.private();
        while (priv.groups_flow.as(gtk.Widget).getFirstChild()) |child| {
            priv.groups_flow.remove(child);
        }
        while (priv.hosts_flow.as(gtk.Widget).getFirstChild()) |child| {
            priv.hosts_flow.remove(child);
        }
        priv.cards = .empty;
        priv.group_cards = .empty;
        priv.active_group = null;
    }

    /// Load hosts + groups from the vault and rebuild the card grid.
    fn reload(self: *Self) void {
        const priv = self.private();
        self.clearGrid();

        if (priv.arena) |*arena| arena.deinit();
        priv.arena = .init(Application.default().allocator());
        const alloc = priv.arena.?.allocator();

        const gpa = Application.default().allocator();
        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load hosts: {}", .{err});
            self.updateVisibility(0, 0);
            return;
        };
        defer hosts.deinit();
        var groups = sarv.vault.loadGroups(gpa) catch |err| {
            log.warn("failed to load groups: {}", .{err});
            self.updateVisibility(0, 0);
            return;
        };
        defer groups.deinit();

        // Group cards, with a live host count per group. The count covers
        // the whole subtree so "Production" also counts "Production > Web".
        for (groups.items) |*group| {
            var count: usize = 0;
            for (hosts.items) |*host| {
                if (sarv.vault.groupInSubtree(groups.items, host.groupID, group.id)) {
                    count += 1;
                }
            }
            const subtitle = std.fmt.allocPrintSentinel(
                alloc,
                "{d} {s}",
                .{ count, if (count == 1) "Host" else "Hosts" },
                0,
            ) catch continue;
            const name = alloc.dupeZ(u8, group.name) catch continue;
            const child = makeCard("folder-symbolic", "sarv-group-icon", name, subtitle, null);
            const gid = alloc.dupeZ(u8, group.id) catch continue;
            priv.group_cards.append(alloc, .{ .id = gid, .child = child }) catch continue;
            priv.groups_flow.append(child.as(gtk.Widget));
        }

        // Host cards.
        for (hosts.items) |*host| {
            const label = if (host.label.len > 0) host.label else host.hostname;
            const title = alloc.dupeZ(u8, label) catch continue;
            const subtitle = if (host.username.len > 0)
                std.fmt.allocPrintSentinel(alloc, "{s}@{s}", .{ host.username, host.hostname }, 0) catch continue
            else
                alloc.dupeZ(u8, host.hostname) catch continue;

            const gpath = sarv.vault.groupPath(alloc, groups.items, host.groupID) catch "";
            const chip: ?[:0]const u8 = if (gpath.len > 0)
                alloc.dupeZ(u8, gpath) catch null
            else
                null;

            const child = makeCard("computer-symbolic", "sarv-host-icon", title, subtitle, chip);
            const id = alloc.dupeZ(u8, host.id) catch continue;
            const search = std.fmt.allocPrint(
                alloc,
                "{s} {s} {s}",
                .{ title, subtitle, gpath },
            ) catch continue;
            // Walk parentID links so the chain holds the host's group and
            // every ancestor; the groups list is gone by filter time.
            var chain: std.ArrayListUnmanaged([]const u8) = .empty;
            var current: ?[]const u8 = host.groupID;
            var guard: usize = 0;
            while (current) |gid| {
                guard += 1;
                if (guard > 64) break;
                const duped = alloc.dupe(u8, gid) catch break;
                chain.append(alloc, duped) catch break;
                current = for (groups.items) |*g| {
                    if (std.mem.eql(u8, g.id, gid)) break g.parentID;
                } else null;
            }
            priv.cards.append(alloc, .{
                .id = id,
                .search = search,
                .group_chain = chain.items,
                .child = child,
            }) catch continue;
            priv.hosts_flow.append(child.as(gtk.Widget));
        }

        self.updateVisibility(groups.items.len, hosts.items.len);
    }

    fn updateVisibility(self: *Self, group_count: usize, host_count: usize) void {
        const priv = self.private();
        const has_groups = group_count > 0;
        priv.groups_header.as(gtk.Widget).setVisible(@intFromBool(has_groups));
        priv.groups_flow.as(gtk.Widget).setVisible(@intFromBool(has_groups));
        priv.empty_label.as(gtk.Widget).setVisible(@intFromBool(host_count == 0));
    }

    /// Build one card widget: an icon tile plus title/subtitle (and an
    /// optional group chip), matching the macOS hosts grid.
    fn makeCard(
        icon_name: [:0]const u8,
        icon_class: [:0]const u8,
        title: [:0]const u8,
        subtitle: [:0]const u8,
        chip: ?[:0]const u8,
    ) *gtk.FlowBoxChild {
        const box = gtk.Box.new(.horizontal, 12);

        const icon = gtk.Image.newFromIconName(icon_name.ptr);
        icon.setPixelSize(22);
        icon.as(gtk.Widget).addCssClass(icon_class.ptr);
        icon.as(gtk.Widget).setValign(.center);
        box.append(icon.as(gtk.Widget));

        const text_box = gtk.Box.new(.vertical, 2);
        text_box.as(gtk.Widget).setValign(.center);
        text_box.as(gtk.Widget).setHexpand(1);

        const title_label = gtk.Label.new(title.ptr);
        title_label.as(gtk.Widget).setHalign(.start);
        title_label.setMaxWidthChars(18);
        title_label.as(gtk.Widget).addCssClass("title");
        text_box.append(title_label.as(gtk.Widget));

        const subtitle_label = gtk.Label.new(subtitle.ptr);
        subtitle_label.as(gtk.Widget).setHalign(.start);
        subtitle_label.setMaxWidthChars(22);
        subtitle_label.as(gtk.Widget).addCssClass("subtitle");
        subtitle_label.as(gtk.Widget).addCssClass("monospace");
        text_box.append(subtitle_label.as(gtk.Widget));

        if (chip) |chip_text| {
            const chip_label = gtk.Label.new(chip_text.ptr);
            chip_label.as(gtk.Widget).setHalign(.start);
            chip_label.setMaxWidthChars(22);
            chip_label.as(gtk.Widget).addCssClass("dim-label");
            text_box.append(chip_label.as(gtk.Widget));
        }

        box.append(text_box.as(gtk.Widget));

        const child = gtk.FlowBoxChild.new();
        child.as(gtk.Widget).addCssClass("sarv-card");
        child.setChild(box.as(gtk.Widget));
        return child;
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.applyFilter();
    }

    /// Show each host card iff it matches the search text (case-insensitive)
    /// and the active group filter, when one is set.
    fn applyFilter(self: *Self) void {
        const priv = self.private();
        const text_c = priv.search.as(gtk.Editable).getText();
        const text = std.mem.span(text_c);
        for (priv.cards.items) |*card| {
            const search_ok = text.len == 0 or
                std.ascii.indexOfIgnoreCase(card.search, text) != null;
            const group_ok = if (priv.active_group) |active| blk: {
                for (card.group_chain) |gid| {
                    if (std.mem.eql(u8, gid, active)) break :blk true;
                }
                break :blk false;
            } else true;
            card.child.as(gtk.Widget).setVisible(@intFromBool(search_ok and group_ok));
        }
    }

    /// A group card was clicked: filter the host grid to that group, or
    /// clear the filter when the active group is clicked again.
    fn groupActivated(_: *gtk.FlowBox, child: *gtk.FlowBoxChild, self: *Self) callconv(.c) void {
        const priv = self.private();
        const clicked: ?[]const u8 = for (priv.group_cards.items) |*gc| {
            if (gc.child == child) break gc.id;
        } else null;
        const id = clicked orelse return;

        if (priv.active_group) |active| {
            if (std.mem.eql(u8, active, id)) {
                priv.active_group = null;
                priv.groups_flow.unselectChild(child);
                self.applyFilter();
                return;
            }
        }
        priv.active_group = id;
        self.applyFilter();
    }

    /// The Terminal button: open a plain shell tab and switch the window
    /// back to the terminal, like the macOS toolbar.
    fn terminalClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();
        window.showTerminalMode();
        _ = self.as(gtk.Widget).activateAction("win.new-tab", null);
    }

    /// Enter in the search bar / the Connect button: treat the text as an
    /// ad-hoc `ssh <target>` quick connect, like the macOS search bar.
    fn quickConnect(_: *gtk.Widget, self: *Self) callconv(.c) void {
        const priv = self.private();
        const text_c = priv.search.as(gtk.Editable).getText();
        const text = std.mem.trim(u8, std.mem.span(text_c), " ");
        if (text.len == 0) return;

        // If the text matches exactly one visible card, connect to it.
        var match: ?*const Card = null;
        var visible: usize = 0;
        for (priv.cards.items) |*card| {
            if (card.child.as(gtk.Widget).getVisible() != 0) {
                visible += 1;
                match = card;
            }
        }
        if (visible == 1) {
            self.connectHostById(match.?.id);
            return;
        }

        // Otherwise treat it as a raw ssh destination. Reject anything with
        // whitespace so the text can't smuggle extra arguments.
        if (std.mem.indexOfAny(u8, text, " \t") != null) return;
        const gpa = Application.default().allocator();
        var host: sarv.model.SavedHost = .{ .id = "", .hostname = text };
        if (std.mem.indexOfScalar(u8, text, '@')) |at| {
            host.username = text[0..at];
            host.hostname = text[at + 1 ..];
        }
        host.authMethod = .ask;
        const cmd_str = sarv.ssh.command(gpa, &host, false) catch return;
        defer gpa.free(cmd_str);
        self.openTab(cmd_str, host.hostname);
    }

    fn hostActivated(_: *gtk.FlowBox, child: *gtk.FlowBoxChild, self: *Self) callconv(.c) void {
        const priv = self.private();
        for (priv.cards.items) |*card| {
            if (card.child == child) {
                self.connectHostById(card.id);
                return;
            }
        }
    }

    fn addClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();
        const editor = SarvHostEditor.new();
        defer editor.unref();
        _ = SarvHostEditor.signals.saved.connect(editor, *Self, editorSaved, self, .{});
        editor.presentNew(window.as(gtk.Widget));
    }

    fn editorSaved(_: *SarvHostEditor, self: *Self) callconv(.c) void {
        self.reload();
    }

    fn syncClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.openSection(SarvSyncDialog);
    }

    fn filesClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.openSection(SarvFilesDialog);
    }

    /// Sidebar navigation. Hosts is this view; the other sections open
    /// their existing dialogs, then the selection bounces back to Hosts.
    fn sidebarSelected(_: *gtk.ListBox, row_: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.reselecting) return;
        const row = row_ orelse return;
        const section: Section = switch (row.getIndex()) {
            0...4 => @enumFromInt(row.getIndex()),
            else => return,
        };
        switch (section) {
            .hosts => {},
            .keychain => self.openSection(SarvKeysDialog),
            .port_forwarding => self.openSection(SarvTunnelsDialog),
            .snippets => self.openSection(SarvSnippetsDialog),
            .known_hosts => self.openSection(SarvKnownHostsDialog),
        }
        if (section != .hosts) self.selectHostsRow();
    }

    fn openSection(self: *Self, comptime Dialog: type) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();
        const dialog = Dialog.new();
        defer dialog.unref();
        dialog.present(window);
    }

    fn selectHostsRow(self: *Self) void {
        const priv = self.private();
        priv.reselecting = true;
        defer priv.reselecting = false;
        if (priv.sidebar.getRowAtIndex(@intFromEnum(Section.hosts))) |row| {
            priv.sidebar.selectRow(row);
        }
    }

    /// Load the full host by id (so we have the password and every SSH
    /// option) and open an SSH tab for it. Mirrors the hosts dialog flow.
    fn connectHostById(self: *Self, id: []const u8) void {
        const gpa = Application.default().allocator();
        var hosts = sarv.vault.loadHosts(gpa) catch |err| {
            log.warn("failed to load host for connect: {}", .{err});
            return;
        };
        defer hosts.deinit();
        const host = for (hosts.items) |*h| {
            if (std.mem.eql(u8, h.id, id)) break h;
        } else return;

        // When a password is stored, feed it to ssh out-of-band via
        // SSH_ASKPASS; otherwise a plain command lets ssh use keys/agent.
        const cmd_str: []u8 = blk: {
            if (host.password.len > 0) {
                var env = sarv.askpass.prepare(gpa, host.password) catch |err| {
                    log.warn("askpass prepare failed, connecting without password: {}", .{err});
                    break :blk sarv.ssh.command(gpa, host, false) catch return;
                };
                defer env.deinit();
                break :blk sarv.ssh.commandWithEnv(gpa, host, true, env) catch return;
            }
            break :blk sarv.ssh.command(gpa, host, false) catch return;
        };
        defer gpa.free(cmd_str);

        self.openTab(cmd_str, if (host.label.len > 0) host.label else host.hostname);
    }

    /// Open a new terminal tab running `cmd_str`, titled `title`, and switch
    /// the window back to the terminal.
    fn openTab(self: *Self, cmd_str: []const u8, title: []const u8) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();

        const gpa = Application.default().allocator();
        const cmd_z = gpa.dupeZ(u8, cmd_str) catch return;
        defer gpa.free(cmd_z);
        const title_z = gpa.dupeZ(u8, title) catch null;
        defer if (title_z) |t| gpa.free(t);

        var command: configpkg.Command = undefined;
        command.parseCLI(gpa, cmd_z) catch |err| {
            log.warn("failed to parse ssh command: {}", .{err});
            return;
        };

        window.newTabWithCommand(command, title_z);
        window.showTerminalMode();
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
                    .name = "sarv-vaults-view",
                }),
            );

            class.bindTemplateChildPrivate("root", .{});
            class.bindTemplateChildPrivate("sidebar", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("groups_flow", .{});
            class.bindTemplateChildPrivate("hosts_flow", .{});
            class.bindTemplateChildPrivate("groups_header", .{});
            class.bindTemplateChildPrivate("hosts_header", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("group_activated", &groupActivated);
            class.bindTemplateCallback("terminal_clicked", &terminalClicked);
            class.bindTemplateCallback("quick_connect", &quickConnect);
            class.bindTemplateCallback("host_activated", &hostActivated);
            class.bindTemplateCallback("add_clicked", &addClicked);
            class.bindTemplateCallback("sync_clicked", &syncClicked);
            class.bindTemplateCallback("files_clicked", &filesClicked);
            class.bindTemplateCallback("sidebar_selected", &sidebarSelected);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
