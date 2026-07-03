//! Portable Zig port of the macOS `ShellHistory.swift` shell-history reader.
//!
//! Reads the user's shell command history (zsh / bash / fish) so any past
//! command can be surfaced (e.g. saved as a snippet). The Swift original is a
//! single unified parser that strips zsh/fish prefixes inline; this port splits
//! it into explicit, individually testable per-shell parsers that also recover
//! the timestamp when the format carries one. The higher-level `recent` /
//! `loadAll` helpers reproduce the Swift ordering exactly:
//!
//!   * newest-first (input is reversed), and
//!   * de-duplicated, keeping the most-recent occurrence of each command.
//!
//! Caller owns all returned allocations. Each parser returns a slice of
//! `Command`; every `Command.command` (and the slice itself) is heap-allocated
//! and must be freed with `freeCommands`.

const std = @import("std");

pub const Command = struct {
    /// Command text. Heap-allocated; freed by `freeCommands`.
    command: []const u8,
    /// Unix timestamp in seconds when the shell recorded a time, else null.
    timestamp: ?i64 = null,
};

/// Which shell a history file belongs to, inferred from its path/name.
pub const Shell = enum { zsh, bash, fish };

/// Free a slice returned by any parser or by `recent` / `loadAll`.
pub fn freeCommands(alloc: std.mem.Allocator, cmds: []Command) void {
    for (cmds) |c| alloc.free(c.command);
    alloc.free(cmds);
}

/// Parse zsh history.
///
/// zsh "extended history" lines look like `: 1700000000:0;the command`, i.e. a
/// `: <started>:<elapsed>;` prefix followed by the command. Plain lines (no
/// prefix) are kept verbatim. The timestamp is recovered from the extended
/// form. Trailing-backslash continuation is NOT joined — the Swift original
/// splits purely on `\n`, so each physical line is its own command; we mirror
/// that to keep parity.
///
/// Caller owns the result (free with `freeCommands`).
pub fn parseZsh(alloc: std.mem.Allocator, contents: []const u8) ![]Command {
    var list: std.ArrayList(Command) = .empty;
    errdefer freeList(alloc, &list);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        var ts: ?i64 = null;

        // Extended history: ": <ts>:<dur>;<command>".
        if (line.len > 0 and line[0] == ':') {
            if (std.mem.indexOfScalar(u8, line, ';')) |semi| {
                ts = parseZshTimestamp(line[0..semi]);
                line = line[semi + 1 ..];
            }
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try appendCommand(alloc, &list, trimmed, ts);
    }

    return list.toOwnedSlice(alloc);
}

/// Extract the seconds timestamp from a zsh prefix like `: 1700000000:0`.
fn parseZshTimestamp(prefix: []const u8) ?i64 {
    // Drop the leading ':' and surrounding whitespace, then take digits up to
    // the ':' that separates started-time from elapsed-time.
    var s = std.mem.trim(u8, prefix, ": \t");
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| s = s[0..colon];
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Parse bash history.
///
/// Plain one-command-per-line. When `HISTTIMEFORMAT` is set, bash writes a
/// comment line of the form `#1700000000` before each command; those pure-digit
/// timestamp comments are consumed and attached to the following command rather
/// than emitted as commands themselves. Other `#`-prefixed lines are treated as
/// ordinary commands (bash does not comment its history otherwise).
///
/// Caller owns the result (free with `freeCommands`).
pub fn parseBash(alloc: std.mem.Allocator, contents: []const u8) ![]Command {
    var list: std.ArrayList(Command) = .empty;
    errdefer freeList(alloc, &list);

    var pending_ts: ?i64 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // HISTTIMEFORMAT timestamp comment: `#<digits>`.
        if (line[0] == '#' and isAllDigits(line[1..])) {
            pending_ts = std.fmt.parseInt(i64, line[1..], 10) catch null;
            continue;
        }

        try appendCommand(alloc, &list, line, pending_ts);
        pending_ts = null;
    }

    return list.toOwnedSlice(alloc);
}

/// Parse fish history.
///
/// Fish history is YAML-ish: each entry is a `- cmd: <command>` line optionally
/// followed by `  when: <ts>` (and other indented metadata such as `paths`).
/// The `cmd` value is extracted and fish's escapes (`\n` and `\\`) are
/// unescaped, matching how fish stores multi-line commands. `when` timestamps
/// are attached to the entry they belong to. (The Swift original merely skips
/// `when:` lines and does not unescape; this port is stricter because it also
/// recovers timestamps and multi-line command text.)
///
/// Caller owns the result (free with `freeCommands`).
pub fn parseFish(alloc: std.mem.Allocator, contents: []const u8) ![]Command {
    var list: std.ArrayList(Command) = .empty;
    errdefer freeList(alloc, &list);

    // Because a `cmd` and its `when` are on separate lines, buffer the current
    // entry until we hit the next `- cmd:` (or end of input), then flush.
    var have_entry = false;
    var cur_cmd: []const u8 = "";
    var cur_ts: ?i64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "- cmd:")) {
            if (have_entry) try flushFish(alloc, &list, cur_cmd, cur_ts);
            have_entry = true;
            cur_cmd = std.mem.trim(u8, line["- cmd:".len..], " \t");
            cur_ts = null;
        } else if (indentedKey(line, "when:")) |val| {
            cur_ts = std.fmt.parseInt(i64, std.mem.trim(u8, val, " \t"), 10) catch null;
        }
        // Any other indented metadata (paths, etc.) is ignored.
    }
    if (have_entry) try flushFish(alloc, &list, cur_cmd, cur_ts);

    return list.toOwnedSlice(alloc);
}

/// If `line` is an indented `<key> <value>` entry (e.g. `  when: 123`), return
/// the value slice, else null.
fn indentedKey(line: []const u8, key: []const u8) ?[]const u8 {
    const t = std.mem.trimLeft(u8, line, " \t");
    if (t.len == line.len) return null; // must be indented
    if (!std.mem.startsWith(u8, t, key)) return null;
    return t[key.len..];
}

/// Unescape a fish command value and append it if non-empty.
fn flushFish(alloc: std.mem.Allocator, list: *std.ArrayList(Command), raw: []const u8, ts: ?i64) !void {
    if (raw.len == 0) return;
    const unescaped = try unescapeFish(alloc, raw);
    if (unescaped.len == 0) {
        alloc.free(unescaped);
        return;
    }
    try list.append(alloc, .{ .command = unescaped, .timestamp = ts });
}

/// Unescape fish's `\n` (newline) and `\\` (backslash). Caller owns the result.
fn unescapeFish(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => {
                    try out.append(alloc, '\n');
                    i += 1;
                    continue;
                },
                '\\' => {
                    try out.append(alloc, '\\');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

/// Duplicate `text` onto the heap and append a `Command`.
fn appendCommand(alloc: std.mem.Allocator, list: *std.ArrayList(Command), text: []const u8, ts: ?i64) !void {
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);
    try list.append(alloc, .{ .command = owned, .timestamp = ts });
}

/// Free a partially-built command list on the error path.
fn freeList(alloc: std.mem.Allocator, list: *std.ArrayList(Command)) void {
    for (list.items) |c| alloc.free(c.command);
    list.deinit(alloc);
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Parse `contents` using the parser appropriate for `shell`.
/// Caller owns the result (free with `freeCommands`).
pub fn parse(alloc: std.mem.Allocator, shell: Shell, contents: []const u8) ![]Command {
    return switch (shell) {
        .zsh => parseZsh(alloc, contents),
        .bash => parseBash(alloc, contents),
        .fish => parseFish(alloc, contents),
    };
}

/// Reduce a parsed command list to the newest-first, de-duplicated view the
/// Swift `parse(_:limit:)` produces: iterate input in reverse, keep the first
/// (i.e. most-recent) occurrence of each command text, cap at `limit`.
///
/// Returns freshly-allocated `Command`s; `cmds` is unchanged and still owned by
/// the caller. Free the result with `freeCommands`.
pub fn dedupNewestFirst(alloc: std.mem.Allocator, cmds: []const Command, limit: usize) ![]Command {
    var result: std.ArrayList(Command) = .empty;
    errdefer freeList(alloc, &result);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);

    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        const c = cmds[i];
        if (seen.contains(c.command)) continue;
        try seen.put(alloc, c.command, {});
        try appendCommand(alloc, &result, c.command, c.timestamp);
        if (result.items.len >= limit) break;
    }

    return result.toOwnedSlice(alloc);
}

/// A candidate history file: absolute path plus the shell that owns it.
pub const HistoryFile = struct {
    path: []const u8,
    shell: Shell,
};

/// Infer the shell from a history file path/name.
pub fn detectShell(path: []const u8) ?Shell {
    const base = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, base, "fish") != null) return .fish;
    if (std.mem.indexOf(u8, base, "bash") != null) return .bash;
    if (std.mem.indexOf(u8, base, "zsh") != null) return .zsh;
    return null;
}

/// Resolve candidate history files from the environment, mirroring the Swift
/// `historyFile()` search order: `$HISTFILE` first (if set and existing), then
/// the per-shell defaults under `$HOME`. Only existing files are returned.
///
/// Caller owns the result: free each `.path` and then the slice.
pub fn historyFiles(alloc: std.mem.Allocator) ![]HistoryFile {
    var list: std.ArrayList(HistoryFile) = .empty;
    errdefer {
        for (list.items) |f| alloc.free(f.path);
        list.deinit(alloc);
    }

    // $HISTFILE takes precedence when set and pointing at an existing file.
    if (std.process.getEnvVarOwned(alloc, "HISTFILE")) |hf| {
        defer alloc.free(hf);
        if (hf.len > 0 and fileExists(hf)) {
            const shell = detectShell(hf) orelse .zsh;
            try list.append(alloc, .{ .path = try alloc.dupe(u8, hf), .shell = shell });
        }
    } else |_| {}

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch null;
    defer if (home) |h| alloc.free(h);

    if (home) |h| {
        const defaults = [_]struct { rel: []const u8, shell: Shell }{
            .{ .rel = ".zsh_history", .shell = .zsh },
            .{ .rel = ".bash_history", .shell = .bash },
            .{ .rel = ".local/share/fish/fish_history", .shell = .fish },
        };
        for (defaults) |d| {
            const path = try std.fs.path.join(alloc, &.{ h, d.rel });
            if (fileExists(path)) {
                try list.append(alloc, .{ .path = path, .shell = d.shell });
            } else {
                alloc.free(path);
            }
        }
    }

    return list.toOwnedSlice(alloc);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Read and parse every existing history file, concatenate the results, then
/// apply the Swift ordering (newest-first, de-duplicated, capped at `limit`).
///
/// Files are read leniently: any that cannot be opened/read are skipped. Byte
/// content is treated as-is (history files may contain non-UTF8 bytes; like the
/// Swift lenient decode, we do not reject them).
///
/// Caller owns the result (free with `freeCommands`).
pub fn loadAll(alloc: std.mem.Allocator, limit: usize) ![]Command {
    const files = try historyFiles(alloc);
    defer {
        for (files) |f| alloc.free(f.path);
        alloc.free(files);
    }

    var all: std.ArrayList(Command) = .empty;
    defer freeList(alloc, &all);

    for (files) |f| {
        const contents = std.fs.cwd().readFileAlloc(alloc, f.path, 32 * 1024 * 1024) catch continue;
        defer alloc.free(contents);
        const parsed = parse(alloc, f.shell, contents) catch continue;
        defer freeCommands(alloc, parsed);
        for (parsed) |c| try appendCommand(alloc, &all, c.command, c.timestamp);
    }

    return dedupNewestFirst(alloc, all.items, limit);
}

/// Convenience matching Swift's `recent(limit:)`: newest-first, de-duplicated
/// command text only, from all detected history files. Caller owns the slice
/// and each string.
pub fn recent(alloc: std.mem.Allocator, limit: usize) ![][]const u8 {
    const cmds = try loadAll(alloc, limit);
    defer freeCommands(alloc, cmds);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (cmds) |c| try out.append(alloc, try alloc.dupe(u8, c.command));
    return out.toOwnedSlice(alloc);
}

test "sarv: parseZsh handles extended and plain lines with timestamps" {
    const alloc = std.testing.allocator;
    const contents =
        ": 1700000000:0;ls -la\n" ++
        "cd /tmp\n";
    const cmds = try parseZsh(alloc, contents);
    defer freeCommands(alloc, cmds);

    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("ls -la", cmds[0].command);
    try std.testing.expectEqual(@as(?i64, 1700000000), cmds[0].timestamp);
    try std.testing.expectEqualStrings("cd /tmp", cmds[1].command);
    try std.testing.expectEqual(@as(?i64, null), cmds[1].timestamp);
}

test "sarv: parseBash skips HISTTIMEFORMAT timestamp comments" {
    const alloc = std.testing.allocator;
    const contents =
        "#1700000000\n" ++
        "echo hi\n" ++
        "git status\n";
    const cmds = try parseBash(alloc, contents);
    defer freeCommands(alloc, cmds);

    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("echo hi", cmds[0].command);
    try std.testing.expectEqual(@as(?i64, 1700000000), cmds[0].timestamp);
    try std.testing.expectEqualStrings("git status", cmds[1].command);
    try std.testing.expectEqual(@as(?i64, null), cmds[1].timestamp);
}

test "sarv: parseFish extracts cmd values with when timestamps" {
    const alloc = std.testing.allocator;
    const contents =
        "- cmd: git status\n" ++
        "  when: 1700000000\n" ++
        "- cmd: ls\n";
    const cmds = try parseFish(alloc, contents);
    defer freeCommands(alloc, cmds);

    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("git status", cmds[0].command);
    try std.testing.expectEqual(@as(?i64, 1700000000), cmds[0].timestamp);
    try std.testing.expectEqualStrings("ls", cmds[1].command);
    try std.testing.expectEqual(@as(?i64, null), cmds[1].timestamp);
}

test "sarv: parseFish unescapes newlines and backslashes" {
    const alloc = std.testing.allocator;
    const contents = "- cmd: echo one\\ntwo\\\\three\n";
    const cmds = try parseFish(alloc, contents);
    defer freeCommands(alloc, cmds);

    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqualStrings("echo one\ntwo\\three", cmds[0].command);
}

test "sarv: dedupNewestFirst keeps most-recent occurrence, newest first" {
    const alloc = std.testing.allocator;
    // Oldest-to-newest input; "ls" appears twice.
    const contents =
        "ls\n" ++
        "cd /tmp\n" ++
        "ls\n";
    const parsed = try parseBash(alloc, contents);
    defer freeCommands(alloc, parsed);

    const deduped = try dedupNewestFirst(alloc, parsed, 400);
    defer freeCommands(alloc, deduped);

    try std.testing.expectEqual(@as(usize, 2), deduped.len);
    try std.testing.expectEqualStrings("ls", deduped[0].command); // newest first
    try std.testing.expectEqualStrings("cd /tmp", deduped[1].command);
}

test "sarv: dedupNewestFirst honors the limit" {
    const alloc = std.testing.allocator;
    const cmds = [_]Command{
        .{ .command = "a" },
        .{ .command = "b" },
        .{ .command = "c" },
    };
    const deduped = try dedupNewestFirst(alloc, &cmds, 2);
    defer freeCommands(alloc, deduped);

    try std.testing.expectEqual(@as(usize, 2), deduped.len);
    try std.testing.expectEqualStrings("c", deduped[0].command);
    try std.testing.expectEqualStrings("b", deduped[1].command);
}

test "sarv: detectShell infers shell from filename" {
    try std.testing.expectEqual(Shell.zsh, detectShell("/home/u/.zsh_history").?);
    try std.testing.expectEqual(Shell.bash, detectShell("/home/u/.bash_history").?);
    try std.testing.expectEqual(Shell.fish, detectShell("/home/u/.local/share/fish/fish_history").?);
    try std.testing.expect(detectShell("/home/u/.history") == null);
}
