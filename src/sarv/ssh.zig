//! SSH command construction from a SavedHost — the Zig port of
//! SavedHost.sshCommand (SavedHost.swift). Produces the exact same argv the
//! macOS app builds, so connection behavior is identical across platforms.
//!
//! The result is a single shell-command string (space-joined, with shell
//! quoting) suitable for the GTK apprt's `.shell` Command variant. When a
//! password is supplied, an `env SSH_ASKPASS=… ssh …` prefix feeds it
//! out-of-band (see askpass.zig) — never on the TTY.

const std = @import("std");
const model = @import("model.zig");
const askpass = @import("askpass.zig");

const SavedHost = model.SavedHost;

/// Build the ssh command string for `host`. Caller owns the result.
///
/// `staged` mirrors the macOS "guided connect popup" behavior: it forces
/// `StrictHostKeyChecking=accept-new`, a single password prompt, and a
/// default keepalive — used after an explicit host-key pre-flight.
pub fn command(alloc: std.mem.Allocator, host: *const SavedHost, staged: bool) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }

    try args.append(alloc, try alloc.dupe(u8, "ssh"));

    if (host.port != 22) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-p {d}", .{host.port}));
    }

    if (host.identityFile.len > 0) {
        const expanded = try expandTilde(alloc, host.identityFile);
        defer alloc.free(expanded);
        const quoted = try shellQuote(alloc, expanded);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-i {s}", .{quoted}));
        try args.append(alloc, try alloc.dupe(u8, "-o IdentitiesOnly=yes"));
    }

    if (host.forwardAgent) try args.append(alloc, try alloc.dupe(u8, "-A"));
    if (host.useCompression) try args.append(alloc, try alloc.dupe(u8, "-C"));
    if (host.requestTTY) try args.append(alloc, try alloc.dupe(u8, "-t"));

    if (host.proxyJump.len > 0) {
        const quoted = try shellQuote(alloc, host.proxyJump);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-J {s}", .{quoted}));
    }

    if (host.connectTimeoutSeconds > 0) {
        try args.append(alloc, try std.fmt.allocPrint(
            alloc,
            "-o ConnectTimeout={d}",
            .{host.connectTimeoutSeconds},
        ));
    }

    if (host.serverAliveIntervalSeconds > 0) {
        try args.append(alloc, try std.fmt.allocPrint(
            alloc,
            "-o ServerAliveInterval={d}",
            .{host.serverAliveIntervalSeconds},
        ));
        try args.append(alloc, try alloc.dupe(u8, "-o ServerAliveCountMax=3"));
    } else if (staged) {
        try args.append(alloc, try alloc.dupe(u8, "-o ServerAliveInterval=15"));
        try args.append(alloc, try alloc.dupe(u8, "-o ServerAliveCountMax=3"));
    }

    const host_key_policy = if (staged) "accept-new" else @tagName(host.strictHostKeyChecking);
    try args.append(alloc, try std.fmt.allocPrint(
        alloc,
        "-o StrictHostKeyChecking={s}",
        .{host_key_policy},
    ));
    if (staged) try args.append(alloc, try alloc.dupe(u8, "-o NumberOfPasswordPrompts=1"));

    for (host.localForwards) |f| {
        if (f.len == 0) continue;
        const quoted = try shellQuote(alloc, f);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-L {s}", .{quoted}));
    }
    for (host.remoteForwards) |f| {
        if (f.len == 0) continue;
        const quoted = try shellQuote(alloc, f);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-R {s}", .{quoted}));
    }
    if (host.dynamicForwardPort > 0) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-D {d}", .{host.dynamicForwardPort}));
    }

    const target = if (host.username.len == 0)
        try alloc.dupe(u8, host.hostname)
    else
        try std.fmt.allocPrint(alloc, "{s}@{s}", .{ host.username, host.hostname });
    try args.append(alloc, target);

    const trimmed = std.mem.trim(u8, host.initialCommand, &std.ascii.whitespace);
    if (trimmed.len > 0) {
        try args.append(alloc, try shellQuote(alloc, trimmed));
    }

    return try std.mem.join(alloc, " ", args.items);
}

/// Wrap `command()` with an `env …` prefix that supplies the password to ssh
/// out-of-band via SSH_ASKPASS. `pw_env` comes from askpass.prepare(). Caller
/// owns the result.
pub fn commandWithEnv(
    alloc: std.mem.Allocator,
    host: *const SavedHost,
    staged: bool,
    pw_env: askpass.Env,
) ![]u8 {
    const base = try command(alloc, host, staged);
    defer alloc.free(base);

    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }
    try parts.append(alloc, try alloc.dupe(u8, "env"));
    var it = pw_env.iterator();
    while (it.next()) |kv| {
        const quoted = try shellQuote(alloc, kv.value);
        defer alloc.free(quoted);
        try parts.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ kv.key, quoted }));
    }
    try parts.append(alloc, try alloc.dupe(u8, base));
    return try std.mem.join(alloc, " ", parts.items);
}

/// POSIX-safe token for known_hosts / ssh-keyscan: bare host, or `[host]:port`
/// when a non-default port is used. Caller owns the result.
pub fn knownHostsToken(alloc: std.mem.Allocator, host: []const u8, port: i64) ![]u8 {
    if (port == 22) return alloc.dupe(u8, host);
    return std.fmt.allocPrint(alloc, "[{s}]:{d}", .{ host, port });
}

/// Shell-quote a string the same way the macOS app does: return as-is when it
/// contains only safe characters, otherwise single-quote and escape embedded
/// single quotes as '\''. Caller owns the result. Shared with other modules
/// that build shell command strings (sftp, port forwarding).
pub fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (isSafe(s)) return alloc.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

fn isSafe(s: []const u8) bool {
    if (s.len == 0) return false; // empty must be quoted to survive
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '@', '%', '+', '=', ':', ',', '.', '/', '-' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// Expand a leading `~` to $HOME. Caller owns the result.
pub fn expandTilde(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return alloc.dupe(u8, path);
    const home = std.posix.getenv("HOME") orelse return alloc.dupe(u8, path);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ home, path[1..] });
}

test "sarv: ssh command for a minimal host" {
    const alloc = std.testing.allocator;
    const host = SavedHost{ .id = "x", .hostname = "example.com", .username = "deploy" };
    const cmd = try command(alloc, &host, false);
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings("ssh -o StrictHostKeyChecking=ask deploy@example.com", cmd);
}

test "sarv: ssh command with port, identity, forwards and remote command" {
    const alloc = std.testing.allocator;
    const host = SavedHost{
        .id = "x",
        .hostname = "10.0.5.20",
        .username = "root",
        .port = 2222,
        .identityFile = "/keys/id_ed25519",
        .useCompression = true,
        .localForwards = &.{"8080:localhost:80"},
        .dynamicForwardPort = 1080,
        .strictHostKeyChecking = .yes,
        .initialCommand = "tmux attach",
    };
    const cmd = try command(alloc, &host, false);
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings(
        "ssh -p 2222 -i /keys/id_ed25519 -o IdentitiesOnly=yes -C" ++
            " -o StrictHostKeyChecking=yes -L 8080:localhost:80 -D 1080" ++
            " root@10.0.5.20 'tmux attach'",
        cmd,
    );
}

test "sarv: staged connect forces accept-new and single prompt" {
    const alloc = std.testing.allocator;
    const host = SavedHost{ .id = "x", .hostname = "h", .strictHostKeyChecking = .yes };
    const cmd = try command(alloc, &host, true);
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "StrictHostKeyChecking=accept-new") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "NumberOfPasswordPrompts=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ServerAliveInterval=15") != null);
}

test "sarv: knownHostsToken brackets non-default ports" {
    const alloc = std.testing.allocator;
    const a = try knownHostsToken(alloc, "h.example", 22);
    defer alloc.free(a);
    try std.testing.expectEqualStrings("h.example", a);
    const b = try knownHostsToken(alloc, "h.example", 2222);
    defer alloc.free(b);
    try std.testing.expectEqualStrings("[h.example]:2222", b);
}
