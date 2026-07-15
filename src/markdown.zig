//! Markdown → HTML rendering for the in-app Markdown viewer.
//!
//! Backed by md4c (see `pkg/md4c`). Rendering lives in the core so every apprt
//! (macOS today, GTK later) shares one implementation and only builds its own
//! viewer UI. Output uses the GFM dialect (tables, task lists, strikethrough,
//! autolinks) with raw HTML DISABLED, so a hostile `.md` cannot inject markup
//! when the result is shown in a WebView.
const std = @import("std");
const md4c = @import("md4c");

/// Render `markdown` (UTF-8) to sanitized HTML (UTF-8). Caller owns the result.
pub fn toHtml(alloc: std.mem.Allocator, markdown: []const u8) error{ RenderFailed, OutOfMemory }![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    const Ctx = struct {
        list: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        oom: bool = false,
    };
    var ctx: Ctx = .{ .list = &buf, .alloc = alloc };

    const sink = struct {
        fn cb(text: [*c]const md4c.c.MD_CHAR, size: md4c.c.MD_SIZE, ud: ?*anyopaque) callconv(.c) void {
            const cx: *Ctx = @ptrCast(@alignCast(ud.?));
            cx.list.appendSlice(cx.alloc, text[0..size]) catch {
                cx.oom = true;
            };
        }
    }.cb;

    const rc = md4c.c.md_html(
        markdown.ptr,
        @intCast(markdown.len),
        sink,
        &ctx,
        md4c.github_safe_flags,
        0,
    );
    if (ctx.oom) return error.OutOfMemory;
    if (rc != 0) return error.RenderFailed;

    return buf.toOwnedSlice(alloc);
}

test "toHtml renders GFM headings and tables" {
    const html = try toHtml(std.testing.allocator, "# Hi\n\n| a | b |\n|---|---|\n| 1 | 2 |\n");
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<table>") != null);
}

test "toHtml escapes raw HTML (safe mode)" {
    const html = try toHtml(std.testing.allocator, "<script>alert(1)</script>\n");
    defer std.testing.allocator.free(html);
    // NOHTML mode escapes rather than passes through a live <script> tag.
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}
