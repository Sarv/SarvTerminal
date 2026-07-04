//! Git backend for encrypted sync — layers on top of the folder backend
//! (sync.zig). The sync directory is a git working tree; before a pull we
//! `git pull` to fetch the newest encrypted payloads, and after a push we
//! commit + push them. The byte formats are identical to the plain folder
//! backend, so a repo synced this way interoperates with a folder synced by
//! any other means (and with the macOS app).
//!
//! Only ciphertext + the plaintext manifest are committed — the master
//! password never touches the repo. All operations shell out to `git`.

const std = @import("std");

pub const Error = error{GitFailed};

/// True if `dir` is (inside) a git working tree.
pub fn isRepo(gpa: std.mem.Allocator, dir: []const u8) bool {
    const r = run(gpa, dir, &.{ "rev-parse", "--is-inside-work-tree" }) catch return false;
    defer gpa.free(r.stdout);
    return r.code == 0;
}

/// Ensure `dir` contains a checkout of `remote_url`. If `dir` is already a
/// repo, this is a no-op. If empty/new and a remote is given, clone into it.
pub fn ensureClone(gpa: std.mem.Allocator, dir: []const u8, remote_url: []const u8) !void {
    if (isRepo(gpa, dir)) return;
    if (remote_url.len == 0) return; // nothing to clone from; folder-only use
    try std.fs.cwd().makePath(dir);
    const r = run(gpa, null, &.{ "clone", remote_url, dir }) catch return Error.GitFailed;
    defer gpa.free(r.stdout);
    if (r.code != 0) return Error.GitFailed;
}

/// Fast-forward pull the newest payloads. Best-effort: a repo with no upstream
/// (before the first push) or no network is not treated as fatal, so a caller
/// can still read whatever is already checked out.
pub fn pull(gpa: std.mem.Allocator, dir: []const u8) void {
    const r = run(gpa, dir, &.{ "pull", "--ff-only" }) catch return;
    gpa.free(r.stdout);
}

/// Stage everything, commit (self-identified so it works in clean CI/headless
/// environments), and push. A no-op "nothing to commit" is not an error. Push
/// is best-effort when no upstream is configured (folder-only repos).
pub fn commitAndPush(gpa: std.mem.Allocator, dir: []const u8, message: []const u8) !void {
    {
        const r = run(gpa, dir, &.{ "add", "-A" }) catch return Error.GitFailed;
        defer gpa.free(r.stdout);
        if (r.code != 0) return Error.GitFailed;
    }
    {
        // Identity via -c so we don't depend on global git config.
        const r = run(gpa, dir, &.{
            "-c",           "user.email=sync@sarv.terminal",
            "-c",           "user.name=Sarv Terminal",
            "commit",       "-m",
            message,
        }) catch return Error.GitFailed;
        defer gpa.free(r.stdout);
        // Non-zero here usually means "nothing to commit" — not fatal.
    }
    // Push only if an upstream exists; ignore failure for folder-only repos.
    const r = run(gpa, dir, &.{ "push" }) catch return;
    gpa.free(r.stdout);
}

const RunResult = struct { code: u8, stdout: []u8 };

/// Run `git [-C dir] args...`, capturing stdout. `dir` null runs in cwd.
fn run(gpa: std.mem.Allocator, dir: ?[]const u8, args: []const []const u8) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    if (dir) |d| {
        try argv.append(gpa, "-C");
        try argv.append(gpa, d);
    }
    try argv.appendSlice(gpa, args);

    var child = std.process.Child.init(argv.items, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(gpa, 4 * 1024 * 1024);
    errdefer gpa.free(stdout);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    return .{ .code = code, .stdout = stdout };
}

test "sarv: git_sync commit/push to a bare remote round-trips a file" {
    const alloc = std.testing.allocator;

    // Skip gracefully if git isn't on PATH (e.g. a minimal build sandbox).
    if (!gitAvailable(alloc)) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const remote = try std.fs.path.join(alloc, &.{ base, "remote.git" });
    defer alloc.free(remote);
    const work = try std.fs.path.join(alloc, &.{ base, "work" });
    defer alloc.free(work);
    const work2 = try std.fs.path.join(alloc, &.{ base, "work2" });
    defer alloc.free(work2);

    // A bare remote to push to.
    {
        const r = try run(alloc, null, &.{ "init", "--bare", "-b", "main", remote });
        defer alloc.free(r.stdout);
        try std.testing.expectEqual(@as(u8, 0), r.code);
    }
    // Clone it, drop a payload, commit + push.
    try ensureClone(alloc, work, remote);
    try std.testing.expect(isRepo(alloc, work));
    const payload_path = try std.fs.path.join(alloc, &.{ work, "hosts.enc" });
    defer alloc.free(payload_path);
    try std.fs.cwd().writeFile(.{ .sub_path = payload_path, .data = "ciphertext" });
    try commitAndPush(alloc, work, "test push");

    // A fresh clone must see the pushed payload.
    try ensureClone(alloc, work2, remote);
    const path2 = try std.fs.path.join(alloc, &.{ work2, "hosts.enc" });
    defer alloc.free(path2);
    const got = try std.fs.cwd().readFileAlloc(alloc, path2, 4096);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("ciphertext", got);
}

fn gitAvailable(gpa: std.mem.Allocator) bool {
    const r = run(gpa, null, &.{"--version"}) catch return false;
    gpa.free(r.stdout);
    return r.code == 0;
}
