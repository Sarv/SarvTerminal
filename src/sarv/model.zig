//! Sarv data models — Zig mirrors of the Swift `Codable` types.
//!
//! The JSON wire format is the cross-platform contract (see SCHEMA.md):
//! field names below ARE the JSON keys, so they intentionally use camelCase
//! and must match the Swift property names exactly. Defaults mirror the
//! Swift manual decoders so missing fields parse the same on both platforms.
//! Dates stay as ISO-8601 strings and UUIDs as lowercase hyphenated strings;
//! the data layer round-trips them without interpretation.

const std = @import("std");

pub const SavedHost = struct {
    pub const AuthMethod = enum { password, publicKey, agent, ask };
    pub const HostKeyChecking = enum { yes, no, ask, @"accept-new" };

    id: []const u8,
    label: []const u8 = "",
    hostname: []const u8 = "",
    port: i64 = 22,
    username: []const u8 = "",
    note: []const u8 = "",
    authMethod: AuthMethod = .password,
    identityFile: []const u8 = "",
    password: []const u8 = "",
    forwardAgent: bool = false,
    strictHostKeyChecking: HostKeyChecking = .ask,
    connectTimeoutSeconds: i64 = 0,
    serverAliveIntervalSeconds: i64 = 0,
    useCompression: bool = false,
    requestTTY: bool = false,
    proxyJump: []const u8 = "",
    localForwards: []const []const u8 = &.{},
    remoteForwards: []const []const u8 = &.{},
    dynamicForwardPort: i64 = 0,
    initialCommand: []const u8 = "",
    groupID: ?[]const u8 = null,
    /// Legacy free-form group string, superseded by groupID.
    group: []const u8 = "",
    tags: []const []const u8 = &.{},
    themeName: []const u8 = "",
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",

    /// Whether enough information is present to attempt an SSH connection.
    pub fn canConnect(self: *const SavedHost) bool {
        return self.hostname.len > 0;
    }
};

pub const HostGroup = struct {
    id: []const u8,
    name: []const u8 = "",
    parentID: ?[]const u8 = null,
    iconSystemName: []const u8 = "folder.fill",
    colorHex: []const u8 = "",
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
};

pub const Snippet = struct {
    id: []const u8,
    name: []const u8 = "",
    command: []const u8 = "",
    pinned: bool = false,
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
};

pub const PortForward = struct {
    pub const Kind = enum { local, remote, dynamic };

    id: []const u8,
    name: []const u8 = "",
    kind: Kind = .local,
    hostID: []const u8,
    bindAddress: []const u8 = "127.0.0.1",
    listenPort: i64 = 8080,
    destinationHost: []const u8 = "localhost",
    destinationPort: i64 = 80,
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
};

pub const ActivityEntry = struct {
    pub const Category = enum { connection, sync, transfer, @"error", info };

    id: []const u8,
    date: []const u8 = "",
    category: Category = .info,
    title: []const u8 = "",
    detail: ?[]const u8 = null,
    success: bool = true,
};

/// Options every model file is parsed with: unknown fields are ignored so
/// newer files from the other platform never break older readers.
pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

test "sarv: SavedHost decodes with Swift-style defaults for missing fields" {
    const alloc = std.testing.allocator;
    const min =
        \\[{"id":"f47ac10b-58cc-4372-a567-0e02b2c3d479","hostname":"10.0.5.20"}]
    ;
    const parsed = try std.json.parseFromSlice([]SavedHost, alloc, min, parse_options);
    defer parsed.deinit();

    const host = parsed.value[0];
    try std.testing.expectEqual(@as(i64, 22), host.port);
    try std.testing.expectEqual(SavedHost.AuthMethod.password, host.authMethod);
    try std.testing.expectEqual(SavedHost.HostKeyChecking.ask, host.strictHostKeyChecking);
    try std.testing.expect(host.groupID == null);
    try std.testing.expect(host.canConnect());
}

test "sarv: SavedHost accept-new host key policy round-trips its raw value" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"f47ac10b-58cc-4372-a567-0e02b2c3d479","strictHostKeyChecking":"accept-new"}]
    ;
    const parsed = try std.json.parseFromSlice([]SavedHost, alloc, json, parse_options);
    defer parsed.deinit();
    try std.testing.expectEqual(
        SavedHost.HostKeyChecking.@"accept-new",
        parsed.value[0].strictHostKeyChecking,
    );
}

test "sarv: PortForward kinds decode from Swift raw values" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"a","hostID":"b","kind":"dynamic","listenPort":1080}]
    ;
    const parsed = try std.json.parseFromSlice([]PortForward, alloc, json, parse_options);
    defer parsed.deinit();
    try std.testing.expectEqual(PortForward.Kind.dynamic, parsed.value[0].kind);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.value[0].bindAddress);
}

test "sarv: ActivityEntry error category decodes despite Zig keyword clash" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"a","category":"error","title":"boom","success":false}]
    ;
    const parsed = try std.json.parseFromSlice([]ActivityEntry, alloc, json, parse_options);
    defer parsed.deinit();
    try std.testing.expectEqual(ActivityEntry.Category.@"error", parsed.value[0].category);
    try std.testing.expect(!parsed.value[0].success);
}

test "sarv: unknown fields from a newer writer are ignored" {
    const alloc = std.testing.allocator;
    const json =
        \\[{"id":"a","name":"s","command":"ls","pinned":true,"futureField":123}]
    ;
    const parsed = try std.json.parseFromSlice([]Snippet, alloc, json, parse_options);
    defer parsed.deinit();
    try std.testing.expect(parsed.value[0].pinned);
}
