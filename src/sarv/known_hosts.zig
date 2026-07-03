//! Reading and editing `~/.ssh/known_hosts` — the Zig port of
//! KnownHosts.swift. The parsing/fingerprint logic is pure and unit-tested;
//! the file and process wrappers shell out to the same OpenSSH tool
//! (`ssh-keygen -R`) the macOS app uses.
//!
//! Entries are matched by their host token when removed. Deleting an entry is
//! delegated to `ssh-keygen -R`, which rewrites the file (useful when a host
//! key changed and ssh refuses to connect).

const std = @import("std");
const hostkey = @import("hostkey.zig");

/// One parsed entry from `~/.ssh/known_hosts`: the display host, the pretty
/// key type, the SHA256 fingerprint, and whether the host field was hashed.
pub const KnownHostEntry = struct {
    /// Display host, e.g. "[127.0.0.1]:2222" or "(hashed)" for `|1|` lines.
    host: []const u8,
    /// Human-friendly key type, e.g. "ED25519", "RSA", "ECDSA".
    keyType: []const u8,
    /// OpenSSH-style fingerprint, e.g. "SHA256:…".
    fingerprint: []const u8,
    /// True when the host field is an OpenSSH hashed host (`|1|…`).
    hashed: bool,
};

/// An arena-backed set of parsed entries. Call `deinit` to free everything.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    entries: []KnownHostEntry,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Parse the contents of a known_hosts file. Each non-empty, non-comment line
/// is `host keytype base64key [comment]`; a leading `@cert-authority` /
/// `@revoked` marker is skipped. Malformed lines are dropped. When the host
/// field starts with `|1|` the entry is hashed and its host is shown as
/// "(hashed)". Caller owns the returned slice (allocated in `alloc`).
pub fn parse(alloc: std.mem.Allocator, contents: []const u8) ![]KnownHostEntry {
    var out: std.ArrayList(KnownHostEntry) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        var toks = std.mem.tokenizeAny(u8, line, " \t");
        var host_field = toks.next() orelse continue;
        // @cert-authority / @revoked marker: the real host is the next token.
        if (host_field.len > 0 and host_field[0] == '@') {
            host_field = toks.next() orelse continue;
        }
        const key_type_raw = toks.next() orelse continue;
        const key_b64 = toks.next() orelse continue;

        const fp = hostkey.fingerprint(alloc, key_b64) catch continue;
        errdefer alloc.free(fp);

        const hashed = std.mem.startsWith(u8, host_field, "|1|");
        const host = if (hashed)
            try alloc.dupe(u8, "(hashed)")
        else
            try alloc.dupe(u8, host_field);
        errdefer alloc.free(host);

        try out.append(alloc, .{
            .host = host,
            .keyType = try alloc.dupe(u8, hostkey.prettyType(key_type_raw)),
            .fingerprint = fp,
            .hashed = hashed,
        });
    }

    return out.toOwnedSlice(alloc);
}

/// Resolve `~/.ssh/known_hosts` from `$HOME`. Caller owns the result.
pub fn knownHostsPath(alloc: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(alloc, &.{ home, ".ssh", "known_hosts" });
}

/// Load and parse `~/.ssh/known_hosts`. A missing file yields an empty list.
/// The result and its slices live in `Loaded.arena`; call `deinit` to free.
pub fn load(gpa: std.mem.Allocator) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const path = try knownHostsPath(alloc);
    const raw = std.fs.cwd().readFileAlloc(
        alloc,
        path,
        32 * 1024 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = &.{} },
        else => return err,
    };

    const entries = try parse(alloc, raw);
    return .{ .arena = arena, .entries = entries };
}

/// Remove all entries for `token` by spawning `ssh-keygen -R <token>`, which
/// rewrites known_hosts. `token` comes from `ssh.knownHostsToken`.
pub fn remove(alloc: std.mem.Allocator, token: []const u8) !void {
    var child = std.process.Child.init(
        &.{ "ssh-keygen", "-R", token },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.SshKeygenFailed,
        else => return error.SshKeygenFailed,
    }
}

/// Append `lines` to `~/.ssh/known_hosts`, creating the `.ssh` directory and
/// the file if needed and ensuring a single trailing newline separates the
/// existing content from the appended block. The write is atomic (temp file
/// + rename).
pub fn addLines(alloc: std.mem.Allocator, lines: []const u8) !void {
    const trimmed = std.mem.trim(u8, lines, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    const path = try knownHostsPath(alloc);
    defer alloc.free(path);

    // Ensure the parent (~/.ssh) exists.
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const existing = std.fs.cwd().readFileAlloc(
        alloc,
        path,
        32 * 1024 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return err,
    };
    defer alloc.free(existing);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, trimmed);
    try out.append(alloc, '\n');

    try writeAtomic(alloc, path, out.items);
}

fn writeAtomic(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(bytes);
    }
    try std.fs.cwd().rename(tmp, path);
}

test "sarv: parse handles ed25519, rsa, hashed, comment and blank lines" {
    const alloc = std.testing.allocator;
    // Valid base64 blobs so fingerprints compute successfully.
    const contents =
        \\# github.com known host
        \\example.com ssh-ed25519 aGVsbG8gd29ybGQ=
        \\
        \\[10.0.0.1]:2222 ssh-rsa aGVsbG8gcnNhIGtleQ== deploy@laptop
        \\|1|abc123=|def456= ssh-ed25519 aGFzaGVkIGtleQ==
    ;
    const entries = try parse(alloc, contents);
    defer {
        for (entries) |e| {
            alloc.free(e.host);
            alloc.free(e.keyType);
            alloc.free(e.fingerprint);
        }
        alloc.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);

    // Normal ed25519 entry.
    try std.testing.expectEqualStrings("example.com", entries[0].host);
    try std.testing.expectEqualStrings("ED25519", entries[0].keyType);
    try std.testing.expect(!entries[0].hashed);

    // RSA entry with a bracketed host and trailing comment.
    try std.testing.expectEqualStrings("[10.0.0.1]:2222", entries[1].host);
    try std.testing.expectEqualStrings("RSA", entries[1].keyType);
    try std.testing.expect(!entries[1].hashed);

    // Hashed entry: host masked, hashed flag set.
    try std.testing.expectEqualStrings("(hashed)", entries[2].host);
    try std.testing.expect(entries[2].hashed);
    try std.testing.expectEqualStrings("ED25519", entries[2].keyType);

    // All fingerprints are OpenSSH SHA256 strings.
    for (entries) |e| {
        try std.testing.expect(std.mem.startsWith(u8, e.fingerprint, "SHA256:"));
    }
}

test "sarv: parse skips malformed lines and @-markers" {
    const alloc = std.testing.allocator;
    const contents =
        \\onlyhost
        \\host ssh-ed25519
        \\@cert-authority ca.example.com ssh-rsa aGVsbG8gd29ybGQ=
    ;
    const entries = try parse(alloc, contents);
    defer {
        for (entries) |e| {
            alloc.free(e.host);
            alloc.free(e.keyType);
            alloc.free(e.fingerprint);
        }
        alloc.free(entries);
    }

    // Only the @cert-authority line is well-formed; its host is unmasked.
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("ca.example.com", entries[0].host);
    try std.testing.expectEqualStrings("RSA", entries[0].keyType);
}

test "sarv: parse of empty contents yields no entries" {
    const alloc = std.testing.allocator;
    const entries = try parse(alloc, "");
    defer alloc.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
