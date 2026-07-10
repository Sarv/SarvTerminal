//! Vault — convenience access to the Sarv host data from the default config
//! location. Wraps the generic stores (store.zig) with the correct file
//! names, encryption keys and the plaintext/encrypted split documented in
//! SCHEMA.md, so UI code just asks for "the hosts" without re-deriving paths.

const std = @import("std");
const model = @import("model.zig");
const paths = @import("paths.zig");
const keys = @import("keys.zig");
const store = @import("store.zig");

const HostStore = store.Store(model.SavedHost);
const GroupStore = store.Store(model.HostGroup);
const SnippetStore = store.Store(model.Snippet);
const PortForwardStore = store.Store(model.PortForward);

pub const hosts_file = "hosts.json"; // encrypted
pub const groups_file = "groups.json"; // plaintext
pub const snippets_file = "snippets.json"; // encrypted
pub const portforwards_file = "portforwards.json"; // encrypted

/// Load all saved hosts. Caller must call `.deinit()` on the result.
pub fn loadHosts(gpa: std.mem.Allocator) !HostStore.Loaded {
    const path = try paths.dataFile(gpa, hosts_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    return HostStore.load(gpa, path, key);
}

/// Persist the full hosts array (encrypted). Callers load, mutate the slice,
/// and save the whole thing back — same whole-file model as the macOS store.
pub fn saveHosts(gpa: std.mem.Allocator, hosts: []const model.SavedHost) !void {
    const path = try paths.dataFile(gpa, hosts_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    try HostStore.save(gpa, path, hosts, key);
}

/// Insert `host` or replace the existing one with the same id, then persist.
/// When replacing, the stored `createdAt` is preserved. All string data is
/// copied during serialization, so `host`'s borrowed slices only need to live
/// for the duration of this call.
pub fn upsertHost(gpa: std.mem.Allocator, host: model.SavedHost) !void {
    var loaded = try loadHosts(gpa);
    defer loaded.deinit();

    var list: std.ArrayList(model.SavedHost) = .empty;
    defer list.deinit(gpa);

    var replaced = false;
    for (loaded.items) |existing| {
        if (std.mem.eql(u8, existing.id, host.id)) {
            var updated = host;
            updated.createdAt = existing.createdAt; // keep original creation time
            try list.append(gpa, updated);
            replaced = true;
        } else {
            try list.append(gpa, existing);
        }
    }
    if (!replaced) try list.append(gpa, host);

    try saveHosts(gpa, list.items);
}

/// Remove the host with the given id and persist. No-op if absent.
pub fn deleteHost(gpa: std.mem.Allocator, id: []const u8) !void {
    var loaded = try loadHosts(gpa);
    defer loaded.deinit();

    var list: std.ArrayList(model.SavedHost) = .empty;
    defer list.deinit(gpa);
    for (loaded.items) |existing| {
        if (!std.mem.eql(u8, existing.id, id)) try list.append(gpa, existing);
    }
    try saveHosts(gpa, list.items);
}

/// Load all host groups (plaintext, no key). Caller must `.deinit()`.
pub fn loadGroups(gpa: std.mem.Allocator) !GroupStore.Loaded {
    const path = try paths.dataFile(gpa, groups_file);
    defer gpa.free(path);
    return GroupStore.load(gpa, path, null);
}

/// Persist the full groups array (plaintext, matching the macOS store).
pub fn saveGroups(gpa: std.mem.Allocator, groups: []const model.HostGroup) !void {
    const path = try paths.dataFile(gpa, groups_file);
    defer gpa.free(path);
    try GroupStore.save(gpa, path, groups, null);
}

/// Load all snippets. Caller must `.deinit()`.
pub fn loadSnippets(gpa: std.mem.Allocator) !SnippetStore.Loaded {
    const path = try paths.dataFile(gpa, snippets_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    return SnippetStore.load(gpa, path, key);
}

/// Persist the full snippets array (encrypted).
pub fn saveSnippets(gpa: std.mem.Allocator, snippets: []const model.Snippet) !void {
    const path = try paths.dataFile(gpa, snippets_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    try SnippetStore.save(gpa, path, snippets, key);
}

/// Load all port-forward rules. Caller must `.deinit()`.
pub fn loadPortForwards(gpa: std.mem.Allocator) !PortForwardStore.Loaded {
    const path = try paths.dataFile(gpa, portforwards_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    return PortForwardStore.load(gpa, path, key);
}

/// Resolve a group's display path like "Production > Web" for a given group
/// id, walking parentID links. Returns "" for a nil/unknown id. Caller owns
/// the result (allocated in `gpa`).
pub fn groupPath(
    gpa: std.mem.Allocator,
    groups: []const model.HostGroup,
    group_id: ?[]const u8,
) ![]u8 {
    const id = group_id orelse return gpa.dupe(u8, "");

    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(gpa);

    var current: ?[]const u8 = id;
    var guard: usize = 0;
    while (current) |cid| {
        // Cycle/corruption guard: group trees are shallow in practice.
        guard += 1;
        if (guard > 64) break;
        const g = findGroup(groups, cid) orelse break;
        try chain.append(gpa, g.name);
        current = g.parentID;
    }
    if (chain.items.len == 0) return gpa.dupe(u8, "");

    // chain is leaf→root; join reversed as "root > … > leaf".
    std.mem.reverse([]const u8, chain.items);
    return std.mem.join(gpa, " > ", chain.items);
}

fn findGroup(groups: []const model.HostGroup, id: []const u8) ?*const model.HostGroup {
    for (groups) |*g| {
        if (std.mem.eql(u8, g.id, id)) return g;
    }
    return null;
}

/// Whether `group_id` is `root` itself or nested anywhere under it, walking
/// parentID links. Used so selecting a group also covers the hosts of its
/// subgroups (e.g. "Production" includes "Production > Web").
pub fn groupInSubtree(
    groups: []const model.HostGroup,
    group_id: ?[]const u8,
    root: []const u8,
) bool {
    var current: ?[]const u8 = group_id;
    var guard: usize = 0;
    while (current) |cid| {
        // Cycle/corruption guard: group trees are shallow in practice.
        guard += 1;
        if (guard > 64) return false;
        if (std.mem.eql(u8, cid, root)) return true;
        const g = findGroup(groups, cid) orelse return false;
        current = g.parentID;
    }
    return false;
}

// Sandbox the config dir to a tmp path for the duration of a test.
const TmpConfig = struct {
    dir: std.testing.TmpDir,
    z: [:0]u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !TmpConfig {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try dir.dir.realpathAlloc(alloc, ".");
        defer alloc.free(path);
        const z = try alloc.dupeZ(u8, path);
        const c = struct {
            extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        };
        _ = c.setenv("XDG_CONFIG_HOME", z, 1);
        return .{ .dir = dir, .z = z, .alloc = alloc };
    }
    fn deinit(self: *TmpConfig) void {
        const c = struct {
            extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        };
        _ = c.unsetenv("XDG_CONFIG_HOME");
        self.alloc.free(self.z);
        self.dir.cleanup();
    }
};

test "sarv: upsert adds then updates a host, preserving createdAt" {
    const alloc = std.testing.allocator;
    var cfg = try TmpConfig.init(alloc);
    defer cfg.deinit();

    try upsertHost(alloc, .{
        .id = "h1",
        .label = "web",
        .hostname = "10.0.0.1",
        .createdAt = "2020-01-01T00:00:00Z",
        .updatedAt = "2020-01-01T00:00:00Z",
    });

    // Update the same id with a new createdAt that must be ignored.
    try upsertHost(alloc, .{
        .id = "h1",
        .label = "web-renamed",
        .hostname = "10.0.0.2",
        .createdAt = "2099-01-01T00:00:00Z",
        .updatedAt = "2026-07-04T00:00:00Z",
    });

    var loaded = try loadHosts(alloc);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("web-renamed", loaded.items[0].label);
    try std.testing.expectEqualStrings("10.0.0.2", loaded.items[0].hostname);
    try std.testing.expectEqualStrings("2020-01-01T00:00:00Z", loaded.items[0].createdAt);
}

test "sarv: deleteHost removes only the matching id" {
    const alloc = std.testing.allocator;
    var cfg = try TmpConfig.init(alloc);
    defer cfg.deinit();

    try upsertHost(alloc, .{ .id = "a", .hostname = "1" });
    try upsertHost(alloc, .{ .id = "b", .hostname = "2" });
    try deleteHost(alloc, "a");

    var loaded = try loadHosts(alloc);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("b", loaded.items[0].id);
}

test "sarv: groupPath builds a breadcrumb from parent links" {
    const alloc = std.testing.allocator;
    const groups = [_]model.HostGroup{
        .{ .id = "root", .name = "Production" },
        .{ .id = "child", .name = "Web", .parentID = "root" },
    };
    const p = try groupPath(alloc, &groups, "child");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("Production > Web", p);
}

test "sarv: groupInSubtree matches the group itself and nested children" {
    const groups = [_]model.HostGroup{
        .{ .id = "prod", .name = "Production" },
        .{ .id = "web", .name = "Web", .parentID = "prod" },
        .{ .id = "db", .name = "Databases", .parentID = "prod" },
        .{ .id = "staging", .name = "Staging" },
    };
    try std.testing.expect(groupInSubtree(&groups, "prod", "prod"));
    try std.testing.expect(groupInSubtree(&groups, "web", "prod"));
    try std.testing.expect(groupInSubtree(&groups, "db", "prod"));
    try std.testing.expect(!groupInSubtree(&groups, "staging", "prod"));
    try std.testing.expect(!groupInSubtree(&groups, null, "prod"));
    try std.testing.expect(!groupInSubtree(&groups, "missing", "prod"));
}

test "sarv: groupPath is empty for nil or unknown id" {
    const alloc = std.testing.allocator;
    const groups = [_]model.HostGroup{.{ .id = "root", .name = "Production" }};

    const a = try groupPath(alloc, &groups, null);
    defer alloc.free(a);
    try std.testing.expectEqualStrings("", a);

    const b = try groupPath(alloc, &groups, "missing");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("", b);
}
