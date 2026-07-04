//! Data-key management for at-rest encryption on Linux/FreeBSD.
//!
//! macOS wraps the 256-bit data key with the Secure Enclave (see
//! LocalDataCrypto.swift). Here the durable home for the key is the
//! freedesktop Secret Service (GNOME Keyring / KDE Wallet via libsecret) —
//! that integration lands with the GTK UI phase. Until then this file
//! keystore mirrors the macOS debug-build behavior: a raw key file with
//! owner-only permissions inside the config dir.
//!
//!   <configDir>/keystore/data-key-raw   (0600, dir 0700)

const std = @import("std");
const paths = @import("paths.zig");

pub const key_len = 32;

/// Load the data key, generating and persisting a fresh one on first use.
pub fn getOrCreate(alloc: std.mem.Allocator) ![key_len]u8 {
    const dir_path = try keystoreDir(alloc);
    defer alloc.free(dir_path);

    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();

    // Existing key.
    if (dir.openFile("data-key-raw", .{})) |file| {
        defer file.close();
        var key: [key_len]u8 = undefined;
        const n = try file.readAll(&key);
        if (n == key_len) return key;
        // Truncated/corrupt key file: refuse to guess. Overwriting would
        // silently orphan every encrypted data file.
        return error.CorruptKeystore;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // First use: generate and persist with owner-only permissions.
    var key: [key_len]u8 = undefined;
    std.crypto.random.bytes(&key);
    const file = try dir.createFile("data-key-raw", .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(&key);
    return key;
}

fn keystoreDir(alloc: std.mem.Allocator) ![]const u8 {
    const config = try paths.configDir(alloc);
    defer alloc.free(config);
    const dir = try std.fs.path.join(alloc, &.{ config, "keystore" });
    errdefer alloc.free(dir);
    try std.fs.cwd().makePath(dir);
    // Best-effort owner-only perms. Path-based fchmodat (not Dir.chmod, which
    // fchmod()s the directory handle and asserts `unreachable` on EBADF for an
    // O_PATH-style fd). The key file itself is created 0600, which is the real
    // protection; a stricter dir mode is just defense-in-depth.
    std.posix.fchmodat(std.fs.cwd().fd, dir, 0o700, 0) catch {};
    return dir;
}
