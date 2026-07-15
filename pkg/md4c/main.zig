//! Zig binding for md4c — a CommonMark + GFM Markdown parser and HTML renderer.
//! Upstream: https://github.com/mity/md4c (C, MIT). Vendored for the future
//! in-app Markdown viewer (render + source modes); see ROADMAP.md.
const std = @import("std");

pub const c = @cImport({
    @cInclude("md4c-html.h");
});

/// Parser flags for GitHub-flavored, SAFE rendering: GFM tables, task lists,
/// strikethrough, and permissive autolinks, with raw inline/block HTML DISABLED
/// (`MD_FLAG_NOHTML`) so untrusted markdown can't inject `<script>` when the
/// rendered output is shown in a WebView. Pass to `c.md_html`'s parser_flags.
pub const github_safe_flags: c_uint =
    @as(c_uint, c.MD_FLAG_TABLES) |
    @as(c_uint, c.MD_FLAG_TASKLISTS) |
    @as(c_uint, c.MD_FLAG_STRIKETHROUGH) |
    @as(c_uint, c.MD_FLAG_PERMISSIVEAUTOLINKS) |
    @as(c_uint, c.MD_FLAG_NOHTML);

test "renders GFM markdown (headings + tables) to html" {
    const testing = std.testing;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const Ctx = struct { list: *std.ArrayList(u8), alloc: std.mem.Allocator };
    var ctx: Ctx = .{ .list = &buf, .alloc = testing.allocator };

    const sink = struct {
        fn cb(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, ud: ?*anyopaque) callconv(.c) void {
            const cx: *Ctx = @ptrCast(@alignCast(ud.?));
            cx.list.appendSlice(cx.alloc, text[0..size]) catch {};
        }
    }.cb;

    const md = "# Hello\n\n| a | b |\n|---|---|\n| 1 | 2 |\n";
    const rc = c.md_html(md.ptr, @intCast(md.len), sink, &ctx, github_safe_flags, 0);

    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expect(std.mem.indexOf(u8, buf.items, "<h1>") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "<table>") != null);
}
