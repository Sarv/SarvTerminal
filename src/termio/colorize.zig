//! Native colorization of PLAIN command output (the `output-colorize` option).
//!
//! Runs AFTER the VT parser on each output chunk, on the PRIMARY screen only
//! (never TUIs / the alternate screen). It recolors ONLY cells the program left
//! at the DEFAULT foreground — so any color the program itself emitted is never
//! overridden — and skips the in-progress cursor row (so progress bars drawn
//! with `\r` aren't recolored mid-update). Colors are stored as PALETTE INDICES
//! so they resolve against the active theme (and live SSH-host palette) and
//! track theme changes automatically.
//!
//! Balanced token set: dim `[timestamp]`, colored `[LEVEL]` field, and bare
//! booleans (true/false/yes/no/enabled/disabled). It colors only the bracketed
//! level FIELD (not the word "error" inside a message), but booleans are colored
//! wherever they appear since they're values.

const std = @import("std");
const terminalpkg = @import("../terminal/main.zig");
const style = @import("../terminal/style.zig");

const Terminal = terminalpkg.Terminal;
const Pin = terminalpkg.Pin;
const size = terminalpkg.size;

/// Canonical semantic → ANSI palette-slot map. Every role maps to a palette
/// index; the active theme supplies the actual RGB for that slot, so this adapts
/// to any theme (including ones with unusual backgrounds — the theme tunes its
/// own palette to be readable on itself).
///
/// This MUST stay in sync with the Settings theme preview,
/// `macos/Sources/Features/Settings/ThemePreviewPopover.swift` (`semanticColor`),
/// so the preview shows exactly what the terminal renders.
const Slot = struct {
    const err: u8 = 1; // error / fail / panic ; false / no / disabled
    const ok: u8 = 2; // success / true / yes / enabled
    const warn: u8 = 3; // warn
    const info: u8 = 4; // info / notice ; (rich: path / url)
    const fatal: u8 = 5; // fatal / critical ; (rich: number)
    const debug: u8 = 6; // debug / trace ; (rich: key=)
    // NOTE: timestamps are dimmed via the `faint` flag, NOT a palette slot.
    // No palette index is reliably "dim" across themes — e.g. the Claude
    // theme repurposes slot 8 ("bright black") as a bright salmon accent.
    // `faint` dims the theme foreground by `faint-opacity` (default 0.5),
    // matching the preview's `fg.opacity(0.5)`. See Recolor.faint below.
};

/// What to apply to a cell. Kept as a palette index (resolved live against the
/// theme) or the `faint` flag, so everything tracks theme/SSH-host changes.
const Recolor = union(enum) {
    palette: u8,
    faint,
};

/// Recolor plain output on the terminal's active screen. Cheap no-op on the
/// alternate screen. Must be called with the renderer mutex held.
pub fn colorize(t: *Terminal) void {
    // Never touch full-screen apps (vim, htop, less, …).
    if (t.screens.active_key != .primary) return;

    const screen = t.screens.active;
    const cursor_y = screen.cursor.y;

    var y: size.CellCountInt = 0;
    var it = screen.pages.rowIterator(
        .right_down,
        .{ .active = .{ .x = 0, .y = 0 } },
        null,
    );
    while (it.next()) |pin| : (y += 1) {
        if (y == cursor_y) continue; // in-progress row (may still get \r rewrites)
        if (!pin.isDirty()) continue; // only rows this chunk actually touched
        colorizeRow(pin);
    }
}

fn colorizeRow(pin: Pin) void {
    const cells = pin.cells(.all);

    // Flatten the row into an ASCII scratch buffer, mapping each byte back to
    // the cell column it came from so a match recolors the right cells.
    var text: [512]u8 = undefined;
    var cols: [512]size.CellCountInt = undefined;
    var n: usize = 0;
    for (cells, 0..) |cell, col| {
        if (n >= text.len) break;
        switch (cell.wide) {
            .spacer_tail, .spacer_head => continue, // don't double-count wide chars
            else => {},
        }
        const cp = cell.codepoint();
        // Only ASCII matters for our tokens; anything else is a boundary.
        text[n] = if (cp != 0 and cp < 128) @intCast(cp) else ' ';
        cols[n] = @intCast(col);
        n += 1;
    }

    // 1) Bracketed fields: `[LEVEL]` in its level color, leading `[timestamp]`
    //    dim. Only the bracketed field is colored (not bare "error"/"info" in a
    //    message), matching the theme preview.
    var ts_done = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (text[i] != '[') continue;
        var j = i + 1;
        while (j < n and text[j] != ']') j += 1;
        if (j >= n) break; // unterminated bracket

        const inner = text[i + 1 .. j];
        const trimmed = std.mem.trim(u8, inner, " ");
        if (levelColor(trimmed)) |pal| {
            colorRange(pin, cols[0..n], i, j, .{ .palette = pal }); // whole [LEVEL], brackets incl.
        } else if (!ts_done and looksLikeTimestamp(inner)) {
            colorRange(pin, cols[0..n], i, j, .faint);
            ts_done = true;
        }
        i = j; // resume scanning after this bracket
    }

    // 2) Bare booleans anywhere — they're values (e.g. `hasAI=false`, `sync: true`).
    var w: usize = 0;
    while (w < n) {
        if (!isWordByte(text[w])) {
            w += 1;
            continue;
        }
        const s = w;
        while (w < n and isWordByte(text[w])) w += 1;
        if (boolColor(text[s..w])) |pal| colorRange(pin, cols[0..n], s, w - 1, .{ .palette = pal });
    }
}

fn colorRange(
    pin: Pin,
    cols: []const size.CellCountInt,
    start: usize,
    end: usize,
    rc: Recolor,
) void {
    var k = start;
    while (k <= end) : (k += 1) recolorCell(pin, cols[k], rc);
}

fn isWordByte(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or
        (b >= '0' and b <= '9');
}

/// A bracket body is a timestamp if it has at least one digit and a date/time
/// separator (so `[2026-07-08 15:29:54.433]` matches but `[EmailRepo]` doesn't).
fn looksLikeTimestamp(s: []const u8) bool {
    var has_digit = false;
    var has_sep = false;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            has_digit = true;
        } else if (ch == ':' or ch == '-' or ch == '/' or ch == '.') {
            has_sep = true;
        }
    }
    return has_digit and has_sep;
}

fn levelColor(word: []const u8) ?u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(word, "error") or eq(word, "err") or eq(word, "fail") or
        eq(word, "failed") or eq(word, "panic")) return Slot.err;
    if (eq(word, "fatal") or eq(word, "crit") or eq(word, "critical") or
        eq(word, "severe")) return Slot.fatal;
    if (eq(word, "warn") or eq(word, "warning")) return Slot.warn;
    if (eq(word, "info") or eq(word, "notice")) return Slot.info;
    if (eq(word, "debug") or eq(word, "trace") or eq(word, "verbose")) return Slot.debug;
    return null;
}

/// Bare boolean/status values. Deliberately excludes ambiguous short words like
/// "on"/"off"/"ok" that appear constantly in prose.
fn boolColor(word: []const u8) ?u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(word, "true") or eq(word, "yes") or eq(word, "enabled")) return Slot.ok;
    if (eq(word, "false") or eq(word, "no") or eq(word, "disabled")) return Slot.err;
    return null;
}

/// Set one cell's foreground to a palette index — but only if the program left
/// it at the default fg. Mirrors the add/refcount sequence in
/// `Screen.manualStyleUpdate`, adapted to an arbitrary cell.
fn recolorCell(pin: Pin, col: size.CellCountInt, rc: Recolor) void {
    const page = pin.node.page();
    const cell = &pin.cells(.all)[col];

    const old_id = cell.style_id;
    var new_style: style.Style = if (old_id == style.default_id)
        .{}
    else
        page.styles.get(page.memory, old_id).*;

    // Respect colors the program already applied.
    switch (new_style.fg_color) {
        .none => {},
        else => return,
    }
    switch (rc) {
        // Palette index resolves live against the active theme.
        .palette => |pal| new_style.fg_color = .{ .palette = pal },
        // Dim the (default) theme foreground; leaves fg_color = .none so it
        // still tracks the theme, and preserves any other program flags.
        .faint => new_style.flags.faint = true,
    }

    // Intern the new style (+1 ref). On capacity/rehash failure, skip this cell
    // entirely — never assign a style_id from a failed add, and never run the
    // cursor-only capacity-growth machinery on an arbitrary cell.
    const new_id = page.styles.add(page.memory, new_style) catch return;

    // Release the old ref AFTER a successful add, and only if it wasn't default.
    if (old_id != style.default_id) page.styles.release(page.memory, old_id);

    cell.style_id = new_id;
    const rac = pin.rowAndCell();
    rac.row.styled = true;
    rac.row.dirty = true;
}
