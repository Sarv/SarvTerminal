//! SavedSession — the Zig port of SavedSession.swift (see SCHEMA.md §6).
//!
//! The interesting part is `PaneNode`, a recursive split tree. Swift encodes
//! its indirect enum as `{"leaf": Pane}` or `{"split": {...}}`; Zig's std.json
//! encodes a tagged union the same way (`{"<tag>": value}`), so the layouts are
//! byte-compatible. The recursion is broken with a pointer to `Split` (a union
//! that embedded Split by value would be infinitely sized); std.json allocates
//! and follows the pointer when parsing/serializing.

const std = @import("std");

pub const Kind = enum { local, ssh };
pub const Direction = enum { horizontal, vertical };

/// One terminal pane in a saved layout.
pub const Pane = struct {
    kind: Kind = .local,
    workingDirectory: ?[]const u8 = null,
    hostID: ?[]const u8 = null,
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

/// A horizontal/vertical division of two child nodes.
pub const Split = struct {
    direction: Direction = .horizontal,
    ratio: f64 = 0.5,
    left: PaneNode,
    right: PaneNode,
};

/// A node in the split tree: either a leaf pane or a split of two children.
/// Encodes as `{"leaf": …}` / `{"split": …}` to match the Swift indirect enum.
pub const PaneNode = union(enum) {
    leaf: Pane,
    split: *Split,
};

pub const SavedSession = struct {
    id: []const u8,
    name: []const u8 = "",
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
    colorID: ?[]const u8 = null,
    layout: PaneNode,
};

/// Parse options: sessions must allocate (the recursive `*Split` nodes) and
/// tolerate unknown fields from a newer writer.
pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

test "sarv: session with a single leaf pane round-trips" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"s1","name":"work","createdAt":"2026-07-04T00:00:00Z","updatedAt":"2026-07-04T00:00:00Z","colorID":"blue","layout":{"leaf":{"kind":"local","workingDirectory":"/tmp"}}}]
    ;
    const parsed = try std.json.parseFromSlice([]SavedSession, alloc, json, parse_options);
    defer parsed.deinit();

    const s = parsed.value[0];
    try std.testing.expectEqualStrings("work", s.name);
    try std.testing.expectEqualStrings("blue", s.colorID.?);
    try std.testing.expectEqual(PaneNode.leaf, std.meta.activeTag(s.layout));
    try std.testing.expectEqual(Kind.local, s.layout.leaf.kind);
    try std.testing.expectEqualStrings("/tmp", s.layout.leaf.workingDirectory.?);
}

test "sarv: session with a nested split decodes both children" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"s2","name":"split","layout":{"split":{"direction":"vertical","ratio":0.3,
        \\  "left":{"leaf":{"kind":"local"}},
        \\  "right":{"leaf":{"kind":"ssh","hostID":"h1","title":"prod"}}}}}]
    ;
    const parsed = try std.json.parseFromSlice([]SavedSession, alloc, json, parse_options);
    defer parsed.deinit();

    const layout = parsed.value[0].layout;
    try std.testing.expectEqual(PaneNode.split, std.meta.activeTag(layout));
    try std.testing.expectEqual(Direction.vertical, layout.split.direction);
    try std.testing.expectEqual(@as(f64, 0.3), layout.split.ratio);
    try std.testing.expectEqual(Kind.local, layout.split.left.leaf.kind);
    try std.testing.expectEqual(Kind.ssh, layout.split.right.leaf.kind);
    try std.testing.expectEqualStrings("h1", layout.split.right.leaf.hostID.?);
    try std.testing.expectEqualStrings("prod", layout.split.right.leaf.title.?);
}

test "sarv: session serializes a split layout as tagged objects" {
    const alloc = std.testing.allocator;
    var split: Split = .{
        .direction = .horizontal,
        .ratio = 0.5,
        .left = .{ .leaf = .{ .kind = .local } },
        .right = .{ .leaf = .{ .kind = .ssh, .hostID = "h9" } },
    };
    const session: SavedSession = .{
        .id = "s3",
        .name = "n",
        .layout = .{ .split = &split },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jws: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jws.write(session);
    const json = out.written();

    // Tag-keyed encoding matching the Swift indirect enum.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"split\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"leaf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"direction\":\"horizontal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hostID\":\"h9\"") != null);

    // And it parses back to an equivalent tree.
    const reparsed = try std.json.parseFromSlice(SavedSession, alloc, json, parse_options);
    defer reparsed.deinit();
    try std.testing.expectEqual(Kind.ssh, reparsed.value.layout.split.right.leaf.kind);
}
