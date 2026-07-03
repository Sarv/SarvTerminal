//! Generic JSON array store — load/save for the Sarv data files.
//!
//! Mirrors the Swift stores' on-disk behavior (see SCHEMA.md):
//! - encrypted files are SarvEncEnvelope-wrapped AES-256-GCM
//! - plaintext legacy files are read transparently and migrated on next
//!   save, with the original kept as `<name>.pre-encryption.bak`
//! - missing file loads as an empty list
//! - saves are atomic (temp file + rename)

const std = @import("std");
const envelope = @import("envelope.zig");
const model = @import("model.zig");

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Loaded = struct {
            arena: std.heap.ArenaAllocator,
            items: []T,

            pub fn deinit(self: *Loaded) void {
                self.arena.deinit();
            }
        };

        /// Load the array from `path`. `key` decrypts envelope files; pass
        /// null for plaintext stores (groups.json, activity.json).
        pub fn load(
            gpa: std.mem.Allocator,
            path: []const u8,
            key: ?[envelope.key_len]u8,
        ) !Loaded {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            const raw = std.fs.cwd().readFileAlloc(
                alloc,
                path,
                32 * 1024 * 1024,
            ) catch |err| switch (err) {
                error.FileNotFound => return .{ .arena = arena, .items = &.{} },
                else => return err,
            };

            const json_bytes: []const u8 = bytes: {
                if (key) |k| {
                    if (envelope.isEnvelope(alloc, raw)) {
                        break :bytes try envelope.open(alloc, k, raw);
                    }
                }
                break :bytes raw; // plaintext (legacy or by design)
            };

            const items = try std.json.parseFromSliceLeaky(
                []T,
                alloc,
                json_bytes,
                model.parse_options,
            );
            return .{ .arena = arena, .items = items };
        }

        /// Serialize and atomically write the array to `path`, sealing it
        /// when `key` is provided. Backs up a plaintext predecessor once.
        pub fn save(
            gpa: std.mem.Allocator,
            path: []const u8,
            items: []const T,
            key: ?[envelope.key_len]u8,
        ) !void {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var jws: std.json.Stringify = .{
                .writer = &out.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            try jws.write(items);
            const json_bytes = out.written();

            const payload: []const u8 = payload: {
                if (key) |k| {
                    try backupPlaintextOnce(gpa, path, k);
                    break :payload try envelope.seal(gpa, k, json_bytes);
                }
                break :payload json_bytes;
            };
            defer if (key != null) gpa.free(@constCast(payload));

            try writeAtomic(gpa, path, payload);
        }

        /// First encrypted save over a plaintext file keeps a one-time
        /// backup, matching the macOS migration behavior.
        fn backupPlaintextOnce(
            gpa: std.mem.Allocator,
            path: []const u8,
            k: [envelope.key_len]u8,
        ) !void {
            _ = k;
            const existing = std.fs.cwd().readFileAlloc(
                gpa,
                path,
                32 * 1024 * 1024,
            ) catch return; // missing file: nothing to back up
            defer gpa.free(existing);
            if (envelope.isEnvelope(gpa, existing)) return;

            const bak = try std.fmt.allocPrint(gpa, "{s}.pre-encryption.bak", .{path});
            defer gpa.free(bak);
            std.fs.cwd().access(bak, .{}) catch {
                try std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{});
                return;
            };
        }

        fn writeAtomic(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
            const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
            defer gpa.free(tmp);
            {
                const file = try std.fs.cwd().createFile(tmp, .{ .mode = 0o600 });
                defer file.close();
                try file.writeAll(bytes);
            }
            try std.fs.cwd().rename(tmp, path);
        }
    };
}

test "sarv: store round-trips hosts through an encrypted file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(path);
    const file = try std.fs.path.join(alloc, &.{ path, "hosts.json" });
    defer alloc.free(file);

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    const HostStore = Store(model.SavedHost);
    const hosts = [_]model.SavedHost{
        .{ .id = "f47ac10b-58cc-4372-a567-0e02b2c3d479", .label = "web-prod-01", .hostname = "203.0.113.10", .username = "deploy" },
    };
    try HostStore.save(alloc, file, &hosts, key);

    // On-disk content must be an envelope, not plaintext JSON.
    const raw = try std.fs.cwd().readFileAlloc(alloc, file, 1024 * 1024);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "web-prod-01") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "sarvEnc") != null);

    var loaded = try HostStore.load(alloc, file, key);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("web-prod-01", loaded.items[0].label);
    try std.testing.expectEqualStrings("deploy", loaded.items[0].username);
}

test "sarv: store reads legacy plaintext and backs it up on first encrypted save" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const file = try std.fs.path.join(alloc, &.{ dir_path, "snippets.json" });
    defer alloc.free(file);

    // Simulate a legacy plaintext file written by an old build.
    try std.fs.cwd().writeFile(.{
        .sub_path = file,
        .data = "[{\"id\":\"a\",\"name\":\"list\",\"command\":\"ls -la\"}]",
    });

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);
    const SnippetStore = Store(model.Snippet);

    var loaded = try SnippetStore.load(alloc, file, key);
    try std.testing.expectEqualStrings("ls -la", loaded.items[0].command);

    try SnippetStore.save(alloc, file, loaded.items, key);
    loaded.deinit();

    const bak = try std.fmt.allocPrint(alloc, "{s}.pre-encryption.bak", .{file});
    defer alloc.free(bak);
    const bak_bytes = try std.fs.cwd().readFileAlloc(alloc, bak, 1024 * 1024);
    defer alloc.free(bak_bytes);
    try std.testing.expect(std.mem.indexOf(u8, bak_bytes, "ls -la") != null);

    var reloaded = try SnippetStore.load(alloc, file, key);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("ls -la", reloaded.items[0].command);
}

test "sarv: missing file loads as empty list" {
    const alloc = std.testing.allocator;
    const GroupStore = Store(model.HostGroup);
    var loaded = try GroupStore.load(alloc, "/nonexistent/sarv-test/groups.json", null);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}
