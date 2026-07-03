//! SFTP/SCP file-operation logic — the Zig port of the macOS Files backends
//! (macos/Sources/Features/HostManager/Files/). The focus is on the pure,
//! testable pieces: parsing remote `ls -la` output and scp progress lines,
//! converting between symbolic and octal permissions, and constructing the
//! exact ssh/scp command strings the macOS app uses. Process spawning is left
//! to the caller — these functions only build argv/command strings and parse
//! text, so they stay deterministic and unit-testable.
//!
//! Command strings are single-quoted with ssh.shellQuote (shared with ssh.zig)
//! and mirror RemoteFileBackend.sshOptions()/FileTransfer in the Swift source.
//! Caller owns every returned allocation.

const std = @import("std");
const model = @import("model.zig");
const ssh = @import("ssh.zig");

const SavedHost = model.SavedHost;

/// One entry from a remote directory listing. `name`, when heap-allocated by
/// `parseLsLine`, points into a freshly duped buffer the caller owns; `mtime`
/// likewise. See `parseLsLine` for ownership details.
pub const FileEntry = struct {
    name: []const u8,
    isDir: bool,
    size: u64,
    /// POSIX permission bits (low 9 bits), e.g. 0o755.
    mode: u32,
    /// Modification time exactly as shown by `ls` (e.g. "2024-07-04 12:00" or
    /// "Jul  4 12:00"), for display only — not parsed into a timestamp.
    mtime: []const u8,
    symlink: bool,
};

/// Convert a 9-char symbolic permission string ("rwxr-xr-x") to octal bits
/// (0o755). Unknown characters count as "not set". Only the first 9 chars are
/// considered; shorter input yields zeros for the missing trailing bits.
pub fn permStringToOctal(perms: []const u8) u32 {
    var mode: u32 = 0;
    // Three groups (owner/group/other), each r/w/x worth 4/2/1.
    const weights = [3]u32{ 4, 2, 1 };
    var group: usize = 0;
    while (group < 3) : (group += 1) {
        var bit: usize = 0;
        while (bit < 3) : (bit += 1) {
            const idx = group * 3 + bit;
            if (idx >= perms.len) break;
            const c = perms[idx];
            // 'r'/'w'/'x' set the bit; setuid/setgid/sticky variants
            // (s/S/t/T) also imply the execute-ish position is "on" for our
            // purposes of the low 9 bits, but we only track rwx here.
            const set = switch (bit) {
                0 => c == 'r',
                1 => c == 'w',
                2 => c == 'x' or c == 's' or c == 't',
                else => false,
            };
            if (set) mode |= weights[bit] << @intCast((2 - group) * 3);
        }
    }
    return mode;
}

/// Inverse of `permStringToOctal`: render the low 9 bits of `mode` as
/// "rwxr-xr-x". Caller owns the returned slice.
pub fn octalToPermString(alloc: std.mem.Allocator, mode: u32) ![]u8 {
    var out = try alloc.alloc(u8, 9);
    const chars = [3]u8{ 'r', 'w', 'x' };
    var group: usize = 0;
    while (group < 3) : (group += 1) {
        const bits = (mode >> @intCast((2 - group) * 3)) & 0x7;
        var bit: usize = 0;
        while (bit < 3) : (bit += 1) {
            // bit 0 -> r (value 4), bit 1 -> w (value 2), bit 2 -> x (value 1)
            const mask: u32 = @as(u32, 4) >> @intCast(bit);
            out[group * 3 + bit] = if (bits & mask != 0) chars[bit] else '-';
        }
    }
    return out;
}

/// Parse a single long-format `ls -la` line into a `FileEntry`. Mirrors
/// RemoteFileBackend.parseLS: works for both GNU coreutils and BusyBox output,
/// with or without `--time-style=long-iso`.
///
/// Columns: perms links owner group size <date fields...> name…
///  - long-iso:   drwxr-xr-x 2 user group 4096 2024-07-04 12:00 name
///  - classic:    drwxr-xr-x 2 user group 4096 Jul  4 12:00 name
///
/// Returns null for the `total N` header line, for `.`/`..`, and for any line
/// that doesn't look like a listing entry (too few columns, short perms field).
///
/// Ownership: `name` and `mtime` are duped from `alloc`; on any error nothing
/// is leaked. The caller owns both slices and should free them (or the arena).
pub fn parseLsLine(alloc: std.mem.Allocator, line: []const u8) !?FileEntry {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "total ")) return null;

    // Tokenize on runs of whitespace.
    var cols: std.ArrayList([]const u8) = .empty;
    defer cols.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |tok| try cols.append(alloc, tok);

    // Need at least: perms links owner group size <date field> name.
    if (cols.items.len < 6) return null;
    const perms_field = cols.items[0];
    if (perms_field.len < 10) return null;

    const type_char = perms_field[0];
    const is_dir = type_char == 'd';
    const is_link = type_char == 'l';

    // rwx portion is the 9 chars after the type char.
    const perms = perms_field[1..10];
    const mode = permStringToOctal(perms);

    const size = std.fmt.parseInt(u64, cols.items[4], 10) catch 0;

    // Determine how many columns the date spans, then the rest is the name.
    // long-iso: "YYYY-MM-DD HH:MM"  -> 2 columns (indices 5,6)
    // classic:  "Mon  D  HH:MM|YYYY" -> 3 columns (indices 5,6,7)
    const date_cols: usize = if (looksLikeIsoDate(cols.items[5])) 2 else 3;
    const name_start = 5 + date_cols;
    if (name_start >= cols.items.len) return null;

    // mtime string: join the date columns with single spaces.
    const mtime = try std.mem.join(alloc, " ", cols.items[5..name_start]);
    errdefer alloc.free(mtime);

    // Name is everything from name_start on, re-joined with single spaces to
    // preserve names containing spaces. For symlinks, drop the " -> target".
    var name_joined = try std.mem.join(alloc, " ", cols.items[name_start..]);
    errdefer alloc.free(name_joined);

    if (is_link) {
        if (std.mem.indexOf(u8, name_joined, " -> ")) |arrow| {
            const truncated = try alloc.dupe(u8, name_joined[0..arrow]);
            alloc.free(name_joined);
            name_joined = truncated;
        }
    }

    if (std.mem.eql(u8, name_joined, ".") or std.mem.eql(u8, name_joined, "..")) {
        alloc.free(name_joined);
        alloc.free(mtime);
        return null;
    }

    return FileEntry{
        .name = name_joined,
        .isDir = is_dir,
        .size = size,
        .mode = mode,
        .mtime = mtime,
        .symlink = is_link,
    };
}

/// Heuristic: does the token look like an ISO date "YYYY-MM-DD"?
fn looksLikeIsoDate(tok: []const u8) bool {
    if (tok.len != 10) return false;
    if (tok[4] != '-' or tok[7] != '-') return false;
    for (tok, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The `user@host` (or bare `host`) target string. Caller owns the result.
fn target(alloc: std.mem.Allocator, host: *const SavedHost) ![]u8 {
    if (host.username.len == 0) return alloc.dupe(u8, host.hostname);
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ host.username, host.hostname });
}

/// Common ssh/scp options derived from the host, mirroring
/// RemoteFileBackend.sshOptions(). Appends into `args` (each element newly
/// duped from `alloc`); caller owns/frees the appended items.
fn appendSshOptions(alloc: std.mem.Allocator, args: *std.ArrayList([]const u8), host: *const SavedHost) !void {
    try args.append(alloc, try alloc.dupe(u8, "-o StrictHostKeyChecking=accept-new"));
    try args.append(alloc, try alloc.dupe(u8, "-o BatchMode=no"));
    try args.append(alloc, try alloc.dupe(u8, "-o NumberOfPasswordPrompts=1"));
    if (host.connectTimeoutSeconds > 0) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-o ConnectTimeout={d}", .{host.connectTimeoutSeconds}));
    }
    if (host.identityFile.len > 0) {
        const expanded = try ssh.expandTilde(alloc, host.identityFile);
        defer alloc.free(expanded);
        const quoted = try ssh.shellQuote(alloc, expanded);
        defer alloc.free(quoted);
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-i {s}", .{quoted}));
        try args.append(alloc, try alloc.dupe(u8, "-o IdentitiesOnly=yes"));
    }
}

/// Build the remote-listing command:
///   ssh <opts> [-p PORT] user@host "ls -la --time-style=long-iso '<path>'"
/// long-iso gives a stable, locale-independent, parseable date; parseLsLine
/// tolerates both this and BusyBox's classic format. Caller owns the result.
pub fn remoteListCommand(alloc: std.mem.Allocator, host: *const SavedHost, path: []const u8) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }

    try args.append(alloc, try alloc.dupe(u8, "ssh"));
    try appendSshOptions(alloc, &args, host);
    if (host.port != 22) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-p {d}", .{host.port}));
    }
    try args.append(alloc, try target(alloc, host));

    // The remote command is a single argument, shell-quoted as a whole. The
    // path inside is quoted for the *remote* shell (single quotes, mirroring
    // sftpQuote), then the whole thing is quoted again for the local shell.
    const remote_path = try remoteShellQuote(alloc, path);
    defer alloc.free(remote_path);
    const remote_cmd = try std.fmt.allocPrint(alloc, "ls -la --time-style=long-iso {s}", .{remote_path});
    defer alloc.free(remote_cmd);
    try args.append(alloc, try ssh.shellQuote(alloc, remote_cmd));

    return std.mem.join(alloc, " ", args.items);
}

/// Single-quote a path for a *remote* shell, mirroring Swift's sftpQuote:
/// always wrap in single quotes and escape embedded single quotes as '\''.
/// Caller owns the result.
pub fn remoteShellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
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

/// Build an `scp <opts> -P PORT <localPath> user@host:<remotePath>` upload
/// command. `-r` is added when `is_dir` is set. Caller owns the result.
pub fn scpUpload(
    alloc: std.mem.Allocator,
    host: *const SavedHost,
    local_path: []const u8,
    remote_path: []const u8,
    is_dir: bool,
) ![]u8 {
    const tgt = try target(alloc, host);
    defer alloc.free(tgt);
    const dst = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ tgt, remote_path });
    defer alloc.free(dst);
    return scpCommand(alloc, host, local_path, dst, is_dir);
}

/// Build an `scp <opts> -P PORT user@host:<remotePath> <localPath>` download
/// command. `-r` is added when `is_dir` is set. Caller owns the result.
pub fn scpDownload(
    alloc: std.mem.Allocator,
    host: *const SavedHost,
    remote_path: []const u8,
    local_path: []const u8,
    is_dir: bool,
) ![]u8 {
    const tgt = try target(alloc, host);
    defer alloc.free(tgt);
    const src = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ tgt, remote_path });
    defer alloc.free(src);
    return scpCommand(alloc, host, src, local_path, is_dir);
}

/// Shared scp command builder. `src` and `dst` are used verbatim except for
/// shell quoting. Uses the destination/source host's ssh options + port.
fn scpCommand(
    alloc: std.mem.Allocator,
    host: *const SavedHost,
    src: []const u8,
    dst: []const u8,
    is_dir: bool,
) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }

    try args.append(alloc, try alloc.dupe(u8, "scp"));
    // Preserve modification times/modes, like Swift's `scp -p`.
    try args.append(alloc, try alloc.dupe(u8, "-p"));
    if (is_dir) try args.append(alloc, try alloc.dupe(u8, "-r"));
    try appendSshOptions(alloc, &args, host);
    // scp uses -P (capital) for the port.
    if (host.port != 22) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-P {d}", .{host.port}));
    }
    try args.append(alloc, try ssh.shellQuote(alloc, src));
    try args.append(alloc, try ssh.shellQuote(alloc, dst));

    return std.mem.join(alloc, " ", args.items);
}

/// Build a server-to-server relay command using `scp -3`, which streams both
/// sides through this machine with a single scp invocation. Uses the source
/// host's ssh options (both endpoints must be reachable with them). `-P` is
/// only added for the source's non-default port; per-endpoint ports beyond
/// that would require `scp` URI syntax and are out of scope here (matching the
/// Swift relay, which reconnects per side). Caller owns the result.
pub fn scpServerToServer(
    alloc: std.mem.Allocator,
    src_host: *const SavedHost,
    src_path: []const u8,
    dst_host: *const SavedHost,
    dst_path: []const u8,
    is_dir: bool,
) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }

    try args.append(alloc, try alloc.dupe(u8, "scp"));
    try args.append(alloc, try alloc.dupe(u8, "-3"));
    try args.append(alloc, try alloc.dupe(u8, "-p"));
    if (is_dir) try args.append(alloc, try alloc.dupe(u8, "-r"));
    try appendSshOptions(alloc, &args, src_host);
    if (src_host.port != 22) {
        try args.append(alloc, try std.fmt.allocPrint(alloc, "-P {d}", .{src_host.port}));
    }

    const src_tgt = try target(alloc, src_host);
    defer alloc.free(src_tgt);
    const dst_tgt = try target(alloc, dst_host);
    defer alloc.free(dst_tgt);
    const src_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ src_tgt, src_path });
    defer alloc.free(src_spec);
    const dst_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ dst_tgt, dst_path });
    defer alloc.free(dst_spec);

    try args.append(alloc, try ssh.shellQuote(alloc, src_spec));
    try args.append(alloc, try ssh.shellQuote(alloc, dst_spec));

    return std.mem.join(alloc, " ", args.items);
}

/// Parsed scp progress sample.
pub const ScpProgress = struct {
    percent: u8,
    /// Bytes transferred so far (converted from the printed KB/MB/GB unit).
    transferred: u64,
    /// Rate token exactly as printed by scp (e.g. "1.2MB/s"). Borrows from the
    /// input `line`; copy it if you need to outlive the line.
    rate: []const u8,
};

/// Best-effort parse of an scp progress line. scp prints (per updated file):
///   <filename>   45%  1234KB   1.2MB/s   00:03
/// The filename may contain spaces, so we anchor on the "N%" token and read
/// the two tokens after it (transferred size, rate). Returns null when the
/// line has no recognizable percent token. `rate` borrows from `line`.
pub fn parseScpProgress(line: []const u8) ?ScpProgress {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Find the "N%" token. Scan tokens; pick the first ending in '%' whose
    // leading part is all digits.
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    var tokens: [16][]const u8 = undefined;
    var count: usize = 0;
    while (it.next()) |tok| {
        if (count >= tokens.len) break;
        tokens[count] = tok;
        count += 1;
    }

    var pct_idx: ?usize = null;
    var percent: u8 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const tok = tokens[i];
        if (tok.len >= 2 and tok[tok.len - 1] == '%') {
            const digits = tok[0 .. tok.len - 1];
            if (std.fmt.parseInt(u8, digits, 10)) |p| {
                if (p <= 100) {
                    pct_idx = i;
                    percent = p;
                    break;
                }
            } else |_| {}
        }
    }

    const idx = pct_idx orelse return null;

    // transferred size is the token after the percent, if present.
    var transferred: u64 = 0;
    if (idx + 1 < count) transferred = parseHumanSize(tokens[idx + 1]);

    // rate is the token after that, if present.
    const rate: []const u8 = if (idx + 2 < count) tokens[idx + 2] else "";

    return ScpProgress{ .percent = percent, .transferred = transferred, .rate = rate };
}

/// Parse scp's human size tokens ("1234KB", "1.2MB", "512", "3.0GB") into
/// bytes. Best-effort: unrecognized tokens yield 0.
fn parseHumanSize(tok: []const u8) u64 {
    if (tok.len == 0) return 0;

    // Split trailing unit letters from the leading number.
    var num_end: usize = 0;
    while (num_end < tok.len and (std.ascii.isDigit(tok[num_end]) or tok[num_end] == '.')) : (num_end += 1) {}
    const num_str = tok[0..num_end];
    const unit = tok[num_end..];
    if (num_str.len == 0) return 0;

    const value = std.fmt.parseFloat(f64, num_str) catch return 0;

    const mult: f64 = blk: {
        if (unit.len == 0) break :blk 1;
        break :blk switch (std.ascii.toUpper(unit[0])) {
            'K' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            'T' => 1024.0 * 1024 * 1024 * 1024,
            'B' => 1,
            else => 1,
        };
    };

    const bytes = value * mult;
    if (bytes < 0) return 0;
    return @intFromFloat(bytes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sarv: parseLsLine parses a directory line" {
    const alloc = std.testing.allocator;
    const line = "drwxr-xr-x  2 user group 4096 2024-07-04 12:00 projects";
    const entry = (try parseLsLine(alloc, line)).?;
    defer {
        alloc.free(entry.name);
        alloc.free(entry.mtime);
    }
    try std.testing.expect(entry.isDir);
    try std.testing.expect(!entry.symlink);
    try std.testing.expectEqual(@as(u64, 4096), entry.size);
    try std.testing.expectEqual(@as(u32, 0o755), entry.mode);
    try std.testing.expectEqualStrings("projects", entry.name);
    try std.testing.expectEqualStrings("2024-07-04 12:00", entry.mtime);
}

test "sarv: parseLsLine parses a file line" {
    const alloc = std.testing.allocator;
    const line = "-rw-r--r--  1 user group 12345 2024-07-04 09:30 notes.txt";
    const entry = (try parseLsLine(alloc, line)).?;
    defer {
        alloc.free(entry.name);
        alloc.free(entry.mtime);
    }
    try std.testing.expect(!entry.isDir);
    try std.testing.expectEqual(@as(u64, 12345), entry.size);
    try std.testing.expectEqual(@as(u32, 0o644), entry.mode);
    try std.testing.expectEqualStrings("notes.txt", entry.name);
}

test "sarv: parseLsLine handles classic (non-iso) date and spaced names" {
    const alloc = std.testing.allocator;
    const line = "-rw-r--r-- 1 user group 42 Jul  4 12:00 my file.txt";
    const entry = (try parseLsLine(alloc, line)).?;
    defer {
        alloc.free(entry.name);
        alloc.free(entry.mtime);
    }
    try std.testing.expectEqualStrings("my file.txt", entry.name);
    try std.testing.expectEqualStrings("Jul 4 12:00", entry.mtime);
}

test "sarv: parseLsLine strips symlink target" {
    const alloc = std.testing.allocator;
    const line = "lrwxrwxrwx 1 user group 7 2024-07-04 12:00 link -> /etc/hosts";
    const entry = (try parseLsLine(alloc, line)).?;
    defer {
        alloc.free(entry.name);
        alloc.free(entry.mtime);
    }
    try std.testing.expect(entry.symlink);
    try std.testing.expectEqualStrings("link", entry.name);
}

test "sarv: parseLsLine returns null for total header and dot entries" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try parseLsLine(alloc, "total 8")) == null);
    try std.testing.expect((try parseLsLine(alloc, "drwxr-xr-x 2 u g 4096 2024-07-04 12:00 .")) == null);
    try std.testing.expect((try parseLsLine(alloc, "drwxr-xr-x 2 u g 4096 2024-07-04 12:00 ..")) == null);
    try std.testing.expect((try parseLsLine(alloc, "")) == null);
}

test "sarv: permStringToOctal and octalToPermString round-trip" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0o755), permStringToOctal("rwxr-xr-x"));
    try std.testing.expectEqual(@as(u32, 0o644), permStringToOctal("rw-r--r--"));
    try std.testing.expectEqual(@as(u32, 0o000), permStringToOctal("---------"));
    try std.testing.expectEqual(@as(u32, 0o777), permStringToOctal("rwxrwxrwx"));

    const s = try octalToPermString(alloc, 0o755);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("rwxr-xr-x", s);

    const s2 = try octalToPermString(alloc, 0o644);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("rw-r--r--", s2);

    // Round-trip a range of modes through both directions.
    const modes = [_]u32{ 0o755, 0o644, 0o700, 0o600, 0o777, 0o000, 0o750 };
    for (modes) |m| {
        const str = try octalToPermString(alloc, m);
        defer alloc.free(str);
        try std.testing.expectEqual(m, permStringToOctal(str));
    }
}

test "sarv: remoteListCommand contains target and quoted path" {
    const alloc = std.testing.allocator;
    const host = SavedHost{ .id = "x", .hostname = "example.com", .username = "deploy" };
    const cmd = try remoteListCommand(alloc, &host, "/var/www");
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "deploy@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ls -la --time-style=long-iso") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "/var/www") != null);
    try std.testing.expect(std.mem.startsWith(u8, cmd, "ssh "));
}

test "sarv: remoteListCommand adds -p for non-default port and quotes spaced path" {
    const alloc = std.testing.allocator;
    const host = SavedHost{ .id = "x", .hostname = "h", .username = "u", .port = 2222 };
    const cmd = try remoteListCommand(alloc, &host, "/tmp/my dir");
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-p 2222") != null);
    // The spaced path forces both layers of quoting to appear.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "my dir") != null);
}

test "sarv: scpUpload and scpDownload build src/dst correctly" {
    const alloc = std.testing.allocator;
    const host = SavedHost{ .id = "x", .hostname = "h", .username = "u", .port = 2222 };

    const up = try scpUpload(alloc, &host, "/local/f.txt", "/remote/f.txt", false);
    defer alloc.free(up);
    try std.testing.expect(std.mem.startsWith(u8, up, "scp -p"));
    try std.testing.expect(std.mem.indexOf(u8, up, "-P 2222") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "/local/f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "u@h:/remote/f.txt") != null);

    const down = try scpDownload(alloc, &host, "/remote/d", "/local/d", true);
    defer alloc.free(down);
    try std.testing.expect(std.mem.indexOf(u8, down, "-r") != null);
    try std.testing.expect(std.mem.indexOf(u8, down, "u@h:/remote/d") != null);
    try std.testing.expect(std.mem.indexOf(u8, down, "/local/d") != null);
}

test "sarv: scpServerToServer uses -3 and both host specs" {
    const alloc = std.testing.allocator;
    const src = SavedHost{ .id = "a", .hostname = "src.example", .username = "u1" };
    const dst = SavedHost{ .id = "b", .hostname = "dst.example", .username = "u2" };
    const cmd = try scpServerToServer(alloc, &src, "/data/x", &dst, "/backup/x", false);
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "scp -3") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "u1@src.example:/data/x") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "u2@dst.example:/backup/x") != null);
}

test "sarv: parseScpProgress parses percent, bytes and rate" {
    const p = parseScpProgress("archive.tar  45%  1234KB  1.2MB/s  00:03").?;
    try std.testing.expectEqual(@as(u8, 45), p.percent);
    try std.testing.expectEqual(@as(u64, 1234 * 1024), p.transferred);
    try std.testing.expectEqualStrings("1.2MB/s", p.rate);
}

test "sarv: parseScpProgress handles spaced filename and 100%" {
    const p = parseScpProgress("my big file.iso 100% 4096MB 10.5MB/s 00:00").?;
    try std.testing.expectEqual(@as(u8, 100), p.percent);
    try std.testing.expectEqual(@as(u64, 4096 * 1024 * 1024), p.transferred);
    try std.testing.expectEqualStrings("10.5MB/s", p.rate);
}

test "sarv: parseScpProgress returns null for non-progress lines" {
    try std.testing.expect(parseScpProgress("Connecting to host...") == null);
    try std.testing.expect(parseScpProgress("") == null);
    try std.testing.expect(parseScpProgress("Permission denied") == null);
}
