//! Small shared helpers for the Sarv data layer: v4 UUIDs and ISO-8601
//! UTC timestamps, matching the string formats the macOS app writes (see
//! SCHEMA.md — lowercase hyphenated UUIDs, `YYYY-MM-DDTHH:MM:SSZ` dates).

const std = @import("std");

/// Generate a random v4 UUID as a lowercase hyphenated string.
/// Caller owns the result.
pub fn uuidV4(alloc: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    // Set version (4) and variant (RFC 4122) bits.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        alloc,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

/// Format a Unix timestamp (seconds) as ISO-8601 UTC: `YYYY-MM-DDTHH:MM:SSZ`.
/// Caller owns the result. Pass `std.time.timestamp()` for "now".
pub fn iso8601(alloc: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        },
    );
}

test "sarv: uuidV4 has the right shape and version/variant nibbles" {
    const alloc = std.testing.allocator;
    const id = try uuidV4(alloc);
    defer alloc.free(id);

    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '4'), id[14]); // version 4
    try std.testing.expect(id[19] == '8' or id[19] == '9' or id[19] == 'a' or id[19] == 'b');

    // All lowercase hex outside the hyphens.
    for (id) |c| try std.testing.expect(c == '-' or std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

test "sarv: iso8601 formats a known epoch" {
    const alloc = std.testing.allocator;
    // 2025-07-04T00:00:00Z == 1751587200
    const s = try iso8601(alloc, 1751587200);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("2025-07-04T00:00:00Z", s);
}
