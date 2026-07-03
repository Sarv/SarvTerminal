//! Host-key scanning and known_hosts helpers — the Zig port of
//! HostKeyScanner.swift. Used for the connect pre-flight (know the host key
//! before connecting) and, later, the Known Hosts UI.
//!
//! Process-spawning wrappers shell out to the same OpenSSH tools the macOS
//! app uses (`ssh-keygen -F`, `ssh-keyscan`); the parsing/fingerprint logic
//! is pure and unit-tested.

const std = @import("std");
const ssh = @import("ssh.zig");

/// A parsed host-key scan result: the raw known_hosts lines plus the
/// strongest key's type and SHA256 fingerprint for display.
pub const ScanResult = struct {
    /// All non-comment key lines, ready to append to known_hosts.
    lines: []const u8,
    key_type: []const u8,
    fingerprint: []const u8,
};

/// Compute the OpenSSH-style SHA256 fingerprint of a base64-encoded key blob:
/// `SHA256:` + base64(sha256(key)) with padding stripped. Caller owns result.
pub fn fingerprint(alloc: std.mem.Allocator, base64_key: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const key_len = dec.calcSizeForSlice(base64_key) catch return error.InvalidKey;
    const key = try alloc.alloc(u8, key_len);
    defer alloc.free(key);
    dec.decode(key, base64_key) catch return error.InvalidKey;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});

    const enc = std.base64.standard_no_pad.Encoder;
    const b64 = try alloc.alloc(u8, enc.calcSize(digest.len));
    defer alloc.free(b64);
    _ = enc.encode(b64, &digest);

    return std.fmt.allocPrint(alloc, "SHA256:{s}", .{b64});
}

/// Human-friendly key type from an ssh-keyscan key-type token.
pub fn prettyType(raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "ed25519") != null) return "ED25519";
    if (std.mem.indexOf(u8, raw, "ecdsa") != null) return "ECDSA";
    if (std.mem.indexOf(u8, raw, "rsa") != null) return "RSA";
    if (std.mem.indexOf(u8, raw, "dss") != null) return "DSA";
    return raw;
}

/// Parse `ssh-keyscan` stdout into a ScanResult, preferring the strongest key
/// type (ed25519 > ecdsa > rsa). Returns null when no key lines are present.
/// Caller owns the result and its slices (allocated in `alloc`).
pub fn parseScan(alloc: std.mem.Allocator, output: []const u8) !?ScanResult {
    var key_lines: std.ArrayList([]const u8) = .empty;
    defer key_lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        try key_lines.append(alloc, line);
    }
    if (key_lines.items.len == 0) return null;

    const preferred = pick(key_lines.items, "ed25519") orelse
        pick(key_lines.items, "ecdsa") orelse
        pick(key_lines.items, "rsa") orelse
        key_lines.items[0];

    // A known_hosts line is: `host keytype base64key [comment]`.
    var toks = std.mem.tokenizeScalar(u8, preferred, ' ');
    _ = toks.next(); // host token
    const key_type_raw = toks.next() orelse "";
    const key_b64 = toks.next() orelse "";

    const fp = if (key_b64.len > 0)
        fingerprint(alloc, key_b64) catch try alloc.dupe(u8, "—")
    else
        try alloc.dupe(u8, "—");

    return .{
        .lines = try std.mem.join(alloc, "\n", key_lines.items),
        .key_type = try alloc.dupe(u8, prettyType(key_type_raw)),
        .fingerprint = fp,
    };
}

fn pick(lines: []const []const u8, needle: []const u8) ?[]const u8 {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return line;
    }
    return null;
}

/// True if `token` (from ssh.knownHostsToken) already has an entry in
/// known_hosts, via `ssh-keygen -F`.
pub fn isKnown(alloc: std.mem.Allocator, token: []const u8) bool {
    var child = std.process.Child.init(
        &.{ "ssh-keygen", "-F", token },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const out = child.stdout.?.readToEndAlloc(alloc, 64 * 1024) catch {
        _ = child.wait() catch {};
        return false;
    };
    defer alloc.free(out);
    const term = child.wait() catch return false;
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return ok and std.mem.trim(u8, out, &std.ascii.whitespace).len > 0;
}

/// Run `ssh-keyscan` for a host and parse the strongest key. Returns null on
/// failure or no keys. Caller owns the result.
pub fn scan(alloc: std.mem.Allocator, host: []const u8, port: i64) !?ScanResult {
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return null;

    var child = std.process.Child.init(
        &.{ "ssh-keyscan", "-p", port_str, "-T", "6", host },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const out = child.stdout.?.readToEndAlloc(alloc, 256 * 1024) catch {
        _ = child.wait() catch {};
        return null;
    };
    defer alloc.free(out);
    _ = child.wait() catch return null;

    return parseScan(alloc, out);
}

test "sarv: fingerprint has SHA256 prefix and expected length" {
    const alloc = std.testing.allocator;
    // Any valid base64 blob: SHA256 is 32 bytes → 43 no-pad base64 chars,
    // plus the "SHA256:" prefix = 50.
    const key_b64 = "aGVsbG8gd29ybGQ=";
    const fp = try fingerprint(alloc, key_b64);
    defer alloc.free(fp);
    try std.testing.expect(std.mem.startsWith(u8, fp, "SHA256:"));
    try std.testing.expectEqual(@as(usize, 50), fp.len);
}

test "sarv: parseScan prefers ed25519 and extracts type + fingerprint" {
    const alloc = std.testing.allocator;
    const output =
        \\# example.com:22 SSH-2.0-OpenSSH_9.6
        \\example.com ssh-rsa aGVsbG8gcnNhIGtleQ==
        \\example.com ssh-ed25519 ZWQyNTUxOSBrZXkgZGF0YQ==
        \\
    ;
    const result = (try parseScan(alloc, output)).?;
    defer {
        alloc.free(result.lines);
        alloc.free(result.key_type);
        alloc.free(result.fingerprint);
    }
    try std.testing.expectEqualStrings("ED25519", result.key_type);
    try std.testing.expect(std.mem.startsWith(u8, result.fingerprint, "SHA256:"));
    // Both key lines retained (comment stripped).
    try std.testing.expect(std.mem.indexOf(u8, result.lines, "ssh-rsa") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.lines, "#") == null);
}

test "sarv: parseScan returns null for comment-only output" {
    const alloc = std.testing.allocator;
    const result = try parseScan(alloc, "# nothing here\n# also nothing\n");
    try std.testing.expect(result == null);
}

test "sarv: prettyType maps common key types" {
    try std.testing.expectEqualStrings("ED25519", prettyType("ssh-ed25519"));
    try std.testing.expectEqualStrings("ECDSA", prettyType("ecdsa-sha2-nistp256"));
    try std.testing.expectEqualStrings("RSA", prettyType("ssh-rsa"));
}
