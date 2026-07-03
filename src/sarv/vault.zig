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

/// Load all host groups (plaintext, no key). Caller must `.deinit()`.
pub fn loadGroups(gpa: std.mem.Allocator) !GroupStore.Loaded {
    const path = try paths.dataFile(gpa, groups_file);
    defer gpa.free(path);
    return GroupStore.load(gpa, path, null);
}

/// Load all snippets. Caller must `.deinit()`.
pub fn loadSnippets(gpa: std.mem.Allocator) !SnippetStore.Loaded {
    const path = try paths.dataFile(gpa, snippets_file);
    defer gpa.free(path);
    const key = try keys.getOrCreate(gpa);
    return SnippetStore.load(gpa, path, key);
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
