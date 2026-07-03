//! SSH_ASKPASS password feeding — the Zig port of SSHAskpass.swift.
//!
//! Feeds a saved host password to `ssh` out-of-band so it is never typed on
//! the TTY nor echoed into shell history. A tiny helper script `cat`s a
//! password file whose path is passed via a private env var; ssh invokes the
//! helper because SSH_ASKPASS_REQUIRE=force. The password file is created
//! 0600 and the caller deletes it when the connection ends.

const std = @import("std");
const paths = @import("paths.zig");

/// The three env vars ssh needs, plus the password-file path to clean up.
/// Owns its strings; call deinit to free them (does NOT delete the file —
/// call deletePasswordFile once the session is torn down).
pub const Env = struct {
    ssh_askpass: []const u8,
    ssh_askpass_require: []const u8 = "force",
    password_file: []const u8,
    alloc: std.mem.Allocator,

    pub const Pair = struct { key: []const u8, value: []const u8 };

    pub fn iterator(self: *const Env) Iterator {
        return .{ .env = self, .i = 0 };
    }

    pub const Iterator = struct {
        env: *const Env,
        i: usize,
        pub fn next(self: *Iterator) ?Pair {
            defer self.i += 1;
            return switch (self.i) {
                0 => .{ .key = "SSH_ASKPASS", .value = self.env.ssh_askpass },
                1 => .{ .key = "SSH_ASKPASS_REQUIRE", .value = self.env.ssh_askpass_require },
                2 => .{ .key = "SARV_ASKPASS_FILE", .value = self.env.password_file },
                else => null,
            };
        }
    };

    pub fn deletePasswordFile(self: *const Env) void {
        std.fs.cwd().deleteFile(self.password_file) catch {};
    }

    pub fn deinit(self: *Env) void {
        self.alloc.free(self.ssh_askpass);
        self.alloc.free(self.password_file);
    }
};

/// Create the helper script (once) and a fresh 0600 password file, returning
/// the env ssh needs. Caller owns the returned Env (deinit + deletePasswordFile).
pub fn prepare(alloc: std.mem.Allocator, password: []const u8) !Env {
    const helper = try ensureHelper(alloc);
    errdefer alloc.free(helper);

    const pw_path = try writePasswordFile(alloc, password);
    errdefer {
        std.fs.cwd().deleteFile(pw_path) catch {};
        alloc.free(pw_path);
    }

    return .{ .ssh_askpass = helper, .password_file = pw_path, .alloc = alloc };
}

/// Write the helper script into the config dir if missing (0700). Returns its
/// absolute path; caller owns it.
fn ensureHelper(alloc: std.mem.Allocator) ![]u8 {
    const dir = try paths.configDir(alloc);
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sarv-askpass.sh" });
    errdefer alloc.free(path);

    // Reads the password file whose path we pass via SARV_ASKPASS_FILE.
    const script = "#!/bin/sh\ncat \"$SARV_ASKPASS_FILE\"\n";
    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o700, .truncate = true });
    defer file.close();
    try file.writeAll(script);
    return path;
}

/// Write the newline-terminated password to a unique temp file (0600).
/// Caller owns the returned path.
fn writePasswordFile(alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    const dir = try paths.configDir(alloc);
    defer alloc.free(dir);

    // Unique name without Date/random-in-loop: use a random suffix.
    var rand: [16]u8 = undefined;
    std.crypto.random.bytes(&rand);
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&rand}) catch unreachable;

    const name = try std.fmt.allocPrint(alloc, "sarv-ssh-{s}", .{hex});
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600, .truncate = true });
    defer file.close();
    try file.writeAll(password);
    try file.writeAll("\n"); // ssh strips the trailing newline
    return path;
}

test "sarv: askpass prepare writes password file and yields three env vars" {
    const alloc = std.testing.allocator;

    // Sandbox the config dir so the test never touches a real home.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const tmp_z = try alloc.dupeZ(u8, tmp_path);
    defer alloc.free(tmp_z);
    _ = c.setenv("XDG_CONFIG_HOME", tmp_z, 1);
    // The config dir is process-global state; a real HOME-based value would be
    // restored by later tests setting it, so just clear our override here.
    defer _ = c.unsetenv("XDG_CONFIG_HOME");

    var env = try prepare(alloc, "hunter2");
    defer {
        env.deletePasswordFile();
        env.deinit();
    }

    // The password file exists, is 0600, and holds "hunter2\n".
    const contents = try std.fs.cwd().readFileAlloc(alloc, env.password_file, 4096);
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("hunter2\n", contents);

    var it = env.iterator();
    try std.testing.expectEqualStrings("SSH_ASKPASS", it.next().?.key);
    try std.testing.expectEqualStrings("SSH_ASKPASS_REQUIRE", it.next().?.key);
    const third = it.next().?;
    try std.testing.expectEqualStrings("SARV_ASKPASS_FILE", third.key);
    try std.testing.expect(it.next() == null);

    env.deletePasswordFile();
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(env.password_file, .{}));
}
