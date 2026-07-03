//! SSH port-forward (tunnel) command construction + runtime — the Zig port of
//! PortForwarding.swift / PortForwardManager.swift (macOS HostManager).
//!
//! `tunnelCommand` is the pure, testable core: it builds the `ssh -N …` shell
//! command string that opens a tunnel for a saved `PortForward` rule through a
//! `SavedHost`, mirroring the argv the macOS app assembles. It reuses
//! `ssh.shellQuote` / `ssh.expandTilde` and matches ssh.zig's flag-building
//! style.
//!
//! `Tunnel` is a thin runtime wrapper around `std.process.Child` that spawns the
//! `ssh -N` process non-blocking, reports whether it is up, and kills/reaps it.

const std = @import("std");
const model = @import("model.zig");
const ssh = @import("ssh.zig");

const PortForward = model.PortForward;
const SavedHost = model.SavedHost;

/// Build the `ssh -N …` shell command string that opens `pf`'s tunnel through
/// `host`. Assembled from the host's connection fields directly (not its full
/// sshCommand) so the host's own forwards / initial command don't leak into the
/// tunnel. Caller owns the result.
pub fn tunnelCommand(alloc: std.mem.Allocator, pf: PortForward, host: SavedHost) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }

    try args.append(alloc, try alloc.dupe(u8, "ssh"));
    try args.append(alloc, try alloc.dupe(u8, "-N")); // tunnel only — no remote command

    // Fail fast if the port is busy, plus a keepalive so dropped links surface.
    try args.append(alloc, try alloc.dupe(u8, "-o ExitOnForwardFailure=yes"));
    try args.append(alloc, try alloc.dupe(u8, "-o ServerAliveInterval=15"));
    try args.append(alloc, try alloc.dupe(u8, "-o ServerAliveCountMax=3"));

    if (host.port != 22) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-p {d}", .{host.port}));
    }

    if (host.identityFile.len > 0) {
        const expanded = try ssh.expandTilde(alloc, host.identityFile);
        defer alloc.free(expanded);
        const quoted = try ssh.shellQuote(alloc, expanded);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-i {s}", .{quoted}));
        try args.append(alloc, try alloc.dupe(u8, "-o IdentitiesOnly=yes"));
    }

    if (host.forwardAgent) try args.append(alloc, try alloc.dupe(u8, "-A"));

    switch (pf.kind) {
        .local => {
            const spec = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}:{d}", .{
                pf.bindAddress, pf.listenPort, pf.destinationHost, pf.destinationPort,
            });
            defer alloc.free(spec);
            const quoted = try ssh.shellQuote(alloc, spec);
            defer alloc.free(quoted);
            try args.append(alloc, try std.fmt.allocPrint(alloc, "-L {s}", .{quoted}));
        },
        .remote => {
            const spec = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}:{d}", .{
                pf.bindAddress, pf.listenPort, pf.destinationHost, pf.destinationPort,
            });
            defer alloc.free(spec);
            const quoted = try ssh.shellQuote(alloc, spec);
            defer alloc.free(quoted);
            try args.append(alloc, try std.fmt.allocPrint(alloc, "-R {s}", .{quoted}));
        },
        .dynamic => {
            const spec = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ pf.bindAddress, pf.listenPort });
            defer alloc.free(spec);
            const quoted = try ssh.shellQuote(alloc, spec);
            defer alloc.free(quoted);
            try args.append(alloc, try std.fmt.allocPrint(alloc, "-D {s}", .{quoted}));
        },
    }

    const target = if (host.username.len == 0)
        try alloc.dupe(u8, host.hostname)
    else
        try std.fmt.allocPrint(alloc, "{s}@{s}", .{ host.username, host.hostname });
    try args.append(alloc, target);

    return try std.mem.join(alloc, " ", args.items);
}

/// A live tunnel: owns the spawned `ssh -N` child and its running state. Mirrors
/// PortForwardManager's per-rule Tunnel, minus the SwiftUI/askpass bookkeeping.
///
/// Lifecycle: init → start(alloc) spawns the process; running() reports whether
/// it is up; stop() kills and reaps the child. stop() is idempotent.
pub const Tunnel = struct {
    /// The full `ssh -N …` command string (as built by `tunnelCommand`). Owned
    /// by the caller — Tunnel does not free it.
    command: []const u8,
    child: ?std.process.Child = null,
    is_running: bool = false,
    pid: ?std.process.Child.Id = null,

    pub fn init(command: []const u8) Tunnel {
        return .{ .command = command };
    }

    /// Spawn the tunnel via `/bin/sh -c <command>`, non-blocking. stdin is
    /// closed and stdout/stderr are ignored so the child detaches cleanly.
    pub fn start(self: *Tunnel, alloc: std.mem.Allocator) !void {
        if (self.is_running) return;

        var child = std.process.Child.init(&.{ "/bin/sh", "-c", self.command }, alloc);
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        self.child = child;
        self.pid = child.id;
        self.is_running = true;
    }

    /// Whether the tunnel process is currently up (from our bookkeeping).
    pub fn running(self: *const Tunnel) bool {
        return self.is_running;
    }

    /// Kill the child and reap it. Safe to call when already stopped.
    pub fn stop(self: *Tunnel) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            self.child = null;
        }
        self.is_running = false;
        self.pid = null;
    }
};

test "sarv: tunnelCommand builds a local (-L) forward" {
    const alloc = std.testing.allocator;
    const pf = PortForward{
        .id = "a",
        .hostID = "b",
        .kind = .local,
        .bindAddress = "127.0.0.1",
        .listenPort = 8080,
        .destinationHost = "localhost",
        .destinationPort = 80,
    };
    const host = SavedHost{ .id = "x", .hostname = "h", .username = "u" };
    const cmd = try tunnelCommand(alloc, pf, host);
    defer alloc.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "-N") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-L 127.0.0.1:8080:localhost:80") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "u@h") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ExitOnForwardFailure=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ServerAliveInterval=15") != null);
}

test "sarv: tunnelCommand builds a remote (-R) forward" {
    const alloc = std.testing.allocator;
    const pf = PortForward{
        .id = "a",
        .hostID = "b",
        .kind = .remote,
        .bindAddress = "127.0.0.1",
        .listenPort = 8080,
        .destinationHost = "localhost",
        .destinationPort = 80,
    };
    const host = SavedHost{ .id = "x", .hostname = "h", .username = "u" };
    const cmd = try tunnelCommand(alloc, pf, host);
    defer alloc.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "-N") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-R 127.0.0.1:8080:localhost:80") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "u@h") != null);
}

test "sarv: tunnelCommand builds a dynamic (-D) SOCKS forward" {
    const alloc = std.testing.allocator;
    const pf = PortForward{
        .id = "a",
        .hostID = "b",
        .kind = .dynamic,
        .bindAddress = "127.0.0.1",
        .listenPort = 1080,
    };
    const host = SavedHost{ .id = "x", .hostname = "h", .username = "u" };
    const cmd = try tunnelCommand(alloc, pf, host);
    defer alloc.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "-N") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-D 127.0.0.1:1080") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "u@h") != null);
}

test "sarv: tunnelCommand includes port and identity flags" {
    const alloc = std.testing.allocator;
    const pf = PortForward{
        .id = "a",
        .hostID = "b",
        .kind = .local,
        .bindAddress = "127.0.0.1",
        .listenPort = 8080,
        .destinationHost = "localhost",
        .destinationPort = 80,
    };
    const host = SavedHost{
        .id = "x",
        .hostname = "h",
        .username = "u",
        .port = 2222,
        .identityFile = "/keys/id_ed25519",
    };
    const cmd = try tunnelCommand(alloc, pf, host);
    defer alloc.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "-p 2222") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-i ") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "/keys/id_ed25519") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "IdentitiesOnly=yes") != null);
}
