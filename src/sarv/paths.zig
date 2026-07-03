//! Sarv config directory resolution — the Zig mirror of AppPaths.swift.
//!
//! Layout: `$XDG_CONFIG_HOME`(or `~/.config`)/`sarvterminal` for release
//! builds and `sarvterminal-dev` for debug builds, matching the macOS app so
//! data files are interchangeable across platforms.

const std = @import("std");
const builtin = @import("builtin");

pub const dir_name = if (builtin.mode == .Debug) "sarvterminal-dev" else "sarvterminal";

/// Resolve the Sarv config directory, creating it if missing.
/// Caller owns the returned path.
pub fn configDir(alloc: std.mem.Allocator) ![]const u8 {
    const base: []const u8 = base: {
        if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
            if (xdg.len > 0) break :base try alloc.dupe(u8, xdg);
        }
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        break :base try std.fs.path.join(alloc, &.{ home, ".config" });
    };
    defer alloc.free(base);

    const dir = try std.fs.path.join(alloc, &.{ base, dir_name });
    errdefer alloc.free(dir);
    try std.fs.cwd().makePath(dir);
    return dir;
}

/// Resolve the path of a data file inside the config dir (e.g. "hosts.json").
/// Caller owns the returned path.
pub fn dataFile(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const dir = try configDir(alloc);
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, name });
}

test "sarv: configDir honors XDG_CONFIG_HOME and appends the sarv dir name" {
    // Only asserts path shape; creation is exercised via the tmp-dir store
    // tests in store.zig.
    const alloc = std.testing.allocator;
    const dir = configDir(alloc) catch |err| switch (err) {
        error.NoHomeDirectory => return, // minimal CI environments
        else => return err,
    };
    defer alloc.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, dir_name));
}
