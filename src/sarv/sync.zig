//! Folder-backed encrypted settings sync — the transport that reads/writes the
//! manifest + encrypted payloads to a directory (a local path, or any synced
//! folder like iCloud Drive / Dropbox / a git checkout). Composes sync_crypto
//! for the actual encryption; this module is just the on-disk I/O + protocol.
//!
//! Layout in the sync dir (SCHEMA.md §7/§8):
//!   manifest.json   plaintext (version, salt, iterations, verifier, files)
//!   hosts.enc       AES-256-GCM of {hosts, groups, snippets?}
//!   settings.enc    AES-256-GCM of the settings payload
//!
//! A git backend can layer on top by committing/pulling this directory; the
//! byte formats are identical, so a folder synced by any means round-trips.

const std = @import("std");
const model = @import("model.zig");
const sc = @import("sync_crypto.zig");

pub const manifest_file = "manifest.json";
pub const hosts_file = "hosts.enc";
pub const settings_file = "settings.enc";

pub const Error = error{
    NoManifest,
    WrongPassword,
};

/// What a push writes. `now_iso` is the timestamp string the caller stamps
/// (e.g. util.iso8601(gpa, std.time.timestamp())) so this module stays free of
/// wall-clock calls and is deterministic under test.
pub const PushData = struct {
    dir: []const u8,
    password: []const u8,
    device_name: []const u8,
    now_iso: []const u8,
    hosts: []const model.SavedHost = &.{},
    groups: []const model.HostGroup = &.{},
    snippets: ?[]const model.Snippet = null,
    settings: ?sc.SyncSettingsPayload = null,
};

/// Push encrypted state to the sync dir, returning the new manifest version.
///
/// If a manifest already exists, its salt is reused (so the same password
/// yields the same key) and the password is verified BEFORE overwriting —
/// pushing with the wrong password can't clobber another user's vault.
pub fn push(gpa: std.mem.Allocator, data: PushData) !i64 {
    try std.fs.cwd().makePath(data.dir);

    // Reuse the existing salt + bump version if a manifest is present.
    var salt: [sc.salt_len]u8 = undefined;
    var next_version: i64 = 1;
    if (try readManifest(gpa, data.dir)) |m| {
        defer m.arena.deinit();
        const existing_salt = sc.decodeBase64(gpa, m.value.kdfSalt) catch return Error.NoManifest;
        defer gpa.free(existing_salt);
        if (existing_salt.len != sc.salt_len) return Error.NoManifest;
        @memcpy(&salt, existing_salt);

        // Verify before we overwrite anything.
        const existing_key = sc.deriveKey(data.password, &salt, @intCast(m.value.kdfIterations));
        if (!sc.verifyPassword(gpa, existing_key, m.value.verifier)) return Error.WrongPassword;
        next_version = m.value.version + 1;
    } else {
        std.crypto.random.bytes(&salt);
    }

    const key = sc.deriveKey(data.password, &salt, sc.pbkdf2_iterations);

    // Seal hosts payload.
    const hosts_payload: sc.SyncHostsPayload = .{
        .hosts = data.hosts,
        .groups = data.groups,
        .snippets = data.snippets,
    };
    const hosts_json = try sc.toJson(gpa, hosts_payload, .{ .whitespace = .minified });
    defer gpa.free(hosts_json);
    const hosts_enc = try sc.seal(gpa, key, hosts_json);
    defer gpa.free(hosts_enc);

    // Seal settings payload (only when provided).
    var settings_written = false;
    if (data.settings) |settings| {
        const settings_json = try sc.toJson(gpa, settings, .{
            .whitespace = .minified,
            .emit_null_optional_fields = false,
        });
        defer gpa.free(settings_json);
        const settings_enc = try sc.seal(gpa, key, settings_json);
        defer gpa.free(settings_enc);
        try writeAtomic(gpa, data.dir, settings_file, settings_enc);
        settings_written = true;
    }

    try writeAtomic(gpa, data.dir, hosts_file, hosts_enc);

    // Build + write the manifest last, so a crash mid-push leaves the previous
    // manifest (and thus the previous consistent state) intact.
    const salt_b64 = try sc.encodeBase64(gpa, &salt);
    defer gpa.free(salt_b64);
    const verifier_b64 = try sc.makeVerifier(gpa, key);
    defer gpa.free(verifier_b64);

    const files: []const []const u8 = if (settings_written)
        &.{ settings_file, hosts_file }
    else
        &.{hosts_file};

    const manifest: sc.SyncManifest = .{
        .version = next_version,
        .lastSyncDate = data.now_iso,
        .deviceName = data.device_name,
        .kdfSalt = salt_b64,
        .kdfIterations = sc.pbkdf2_iterations,
        .verifier = verifier_b64,
        .files = files,
    };
    const manifest_json = try sc.toJson(gpa, manifest, .{ .whitespace = .indent_2 });
    defer gpa.free(manifest_json);
    try writeAtomic(gpa, data.dir, manifest_file, manifest_json);

    return next_version;
}

/// Decrypted result of a pull. Everything lives in `arena`.
pub const Pulled = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []const model.SavedHost,
    groups: []const model.HostGroup,
    snippets: ?[]const model.Snippet,
    settings: ?sc.SyncSettingsPayload,
    version: i64,
    device_name: []const u8,

    pub fn deinit(self: *Pulled) void {
        self.arena.deinit();
    }
};

/// Pull + decrypt from the sync dir. Returns Error.WrongPassword when the
/// master password doesn't match the manifest's verifier, Error.NoManifest
/// when the dir has no manifest yet.
pub fn pull(gpa: std.mem.Allocator, dir: []const u8, password: []const u8) !Pulled {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const manifest = (try readManifestInto(alloc, dir)) orelse return Error.NoManifest;

    const salt = sc.decodeBase64(alloc, manifest.kdfSalt) catch return Error.NoManifest;
    if (salt.len != sc.salt_len) return Error.NoManifest;
    var salt_arr: [sc.salt_len]u8 = undefined;
    @memcpy(&salt_arr, salt);

    const key = sc.deriveKey(password, &salt_arr, @intCast(manifest.kdfIterations));
    if (!sc.verifyPassword(gpa, key, manifest.verifier)) return Error.WrongPassword;

    // Hosts payload is always present.
    const hosts_enc = try readFile(alloc, dir, hosts_file);
    const hosts_json = sc.open(gpa, key, hosts_enc) catch return Error.WrongPassword;
    defer gpa.free(hosts_json);
    const hosts_payload = try std.json.parseFromSliceLeaky(
        sc.SyncHostsPayload,
        alloc,
        hosts_json,
        sc.parse_options,
    );

    // Settings payload is optional.
    var settings: ?sc.SyncSettingsPayload = null;
    if (readFile(alloc, dir, settings_file)) |settings_enc| {
        const settings_json = sc.open(gpa, key, settings_enc) catch return Error.WrongPassword;
        defer gpa.free(settings_json);
        settings = try std.json.parseFromSliceLeaky(
            sc.SyncSettingsPayload,
            alloc,
            settings_json,
            sc.parse_options,
        );
    } else |_| {}

    return .{
        .arena = arena,
        .hosts = hosts_payload.hosts,
        .groups = hosts_payload.groups,
        .snippets = hosts_payload.snippets,
        .settings = settings,
        .version = manifest.version,
        .device_name = manifest.deviceName,
    };
}

/// Lightweight status read — parses only the plaintext manifest, no password
/// needed. Returns null when the dir has no manifest.
pub const Status = struct {
    arena: std.heap.ArenaAllocator,
    version: i64,
    device_name: []const u8,
    last_sync_date: []const u8,

    pub fn deinit(self: *Status) void {
        self.arena.deinit();
    }
};

pub fn status(gpa: std.mem.Allocator, dir: []const u8) !?Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const m = (try readManifestInto(arena.allocator(), dir)) orelse {
        arena.deinit();
        return null;
    };
    return .{
        .arena = arena,
        .version = m.version,
        .device_name = m.deviceName,
        .last_sync_date = m.lastSyncDate,
    };
}

// --- internals -------------------------------------------------------------

const ParsedManifest = struct {
    arena: std.heap.ArenaAllocator,
    value: sc.SyncManifest,
};

fn readManifest(gpa: std.mem.Allocator, dir: []const u8) !?ParsedManifest {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const value = (try readManifestInto(arena.allocator(), dir)) orelse {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .value = value };
}

fn readManifestInto(alloc: std.mem.Allocator, dir: []const u8) !?sc.SyncManifest {
    const bytes = readFile(alloc, dir, manifest_file) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try std.json.parseFromSliceLeaky(sc.SyncManifest, alloc, bytes, sc.parse_options);
}

fn readFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
}

fn writeAtomic(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
    try std.fs.cwd().rename(tmp, path);
}

// --- tests -----------------------------------------------------------------

test "sarv: sync push then pull round-trips hosts and bumps version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const hosts = [_]model.SavedHost{
        .{ .id = "h1", .label = "web", .hostname = "10.0.0.1", .username = "deploy" },
    };
    const groups = [_]model.HostGroup{.{ .id = "g1", .name = "Prod" }};

    const v1 = try push(alloc, .{
        .dir = dir,
        .password = "correct horse",
        .device_name = "linux-vm",
        .now_iso = "2026-07-04T00:00:00Z",
        .hosts = &hosts,
        .groups = &groups,
    });
    try std.testing.expectEqual(@as(i64, 1), v1);

    // A second push with the same password bumps the version.
    const v2 = try push(alloc, .{
        .dir = dir,
        .password = "correct horse",
        .device_name = "linux-vm",
        .now_iso = "2026-07-04T01:00:00Z",
        .hosts = &hosts,
        .groups = &groups,
    });
    try std.testing.expectEqual(@as(i64, 2), v2);

    var pulled = try pull(alloc, dir, "correct horse");
    defer pulled.deinit();
    try std.testing.expectEqual(@as(i64, 2), pulled.version);
    try std.testing.expectEqual(@as(usize, 1), pulled.hosts.len);
    try std.testing.expectEqualStrings("web", pulled.hosts[0].label);
    try std.testing.expectEqualStrings("deploy", pulled.hosts[0].username);
    try std.testing.expectEqualStrings("Prod", pulled.groups[0].name);
    try std.testing.expectEqualStrings("linux-vm", pulled.device_name);
}

test "sarv: sync pull with wrong password fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    _ = try push(alloc, .{
        .dir = dir,
        .password = "right",
        .device_name = "d",
        .now_iso = "2026-07-04T00:00:00Z",
        .hosts = &.{.{ .id = "a", .hostname = "h" }},
    });

    try std.testing.expectError(Error.WrongPassword, pull(alloc, dir, "wrong"));
    // Pushing with the wrong password must not clobber the vault either.
    try std.testing.expectError(Error.WrongPassword, push(alloc, .{
        .dir = dir,
        .password = "wrong",
        .device_name = "d",
        .now_iso = "2026-07-04T02:00:00Z",
        .hosts = &.{},
    }));
}

test "sarv: sync status reads manifest without a password" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    try std.testing.expect((try status(alloc, dir)) == null); // no manifest yet

    _ = try push(alloc, .{
        .dir = dir,
        .password = "pw",
        .device_name = "my-laptop",
        .now_iso = "2026-07-04T00:00:00Z",
        .hosts = &.{},
    });

    var st = (try status(alloc, dir)).?;
    defer st.deinit();
    try std.testing.expectEqual(@as(i64, 1), st.version);
    try std.testing.expectEqualStrings("my-laptop", st.device_name);
    try std.testing.expectEqualStrings("2026-07-04T00:00:00Z", st.last_sync_date);
}
