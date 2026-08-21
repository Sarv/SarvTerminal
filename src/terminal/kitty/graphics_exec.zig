const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const Command = command.Command;
const Response = command.Response;
const LoadingImage = image.LoadingImage;
const Image = image.Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;

const log = std.log.scoped(.kitty_gfx);

/// Execute a Kitty graphics command against the given terminal. This
/// will never fail, but the response may indicate an error and the
/// terminal state may not be updated to reflect the command. This will
/// never put the terminal in an unrecoverable state, however.
///
/// The allocator must be the same allocator that was used to build
/// the command.
pub fn execute(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) ?Response {
    // If storage is disabled then we disable the full protocol. This means
    // we don't even respond to queries so the terminal completely acts as
    // if this feature is not supported.
    if (!terminal.screens.active.kitty_images.enabled()) {
        log.debug("kitty graphics requested but disabled", .{});
        return null;
    }

    log.debug("executing kitty graphics command: quiet={} control={}", .{
        cmd.quiet,
        cmd.control,
    });

    // The quiet settings used to control the response. We have to make this
    // a var because in certain special cases (namely chunked transmissions)
    // this can change.
    var quiet = cmd.quiet;

    // The protocol makes i and I mutually exclusive for every action, so this
    // must happen before dispatch and before an action can mutate storage.
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#requesting-image-ids-from-the-terminal
    const identifiers = cmd.control.identifiers();
    if (identifiers.image_id > 0 and identifiers.image_number > 0) {
        const resp: Response = .{
            .id = identifiers.image_id,
            .image_number = identifiers.image_number,
            .placement_id = identifiers.placement_id,
            .message = "EINVAL: image ID and number are mutually exclusive",
        };
        log.warn("erroneous kitty graphics response: {s}", .{resp.message});

        return switch (quiet) {
            .no => resp,
            .ok => resp,
            .failures => null,
        };
    }

    const resp_: ?Response = switch (cmd.control) {
        .query => query(io, alloc, terminal, cmd),
        .display => display(io, alloc, terminal, cmd),
        .delete => delete(io, alloc, terminal, cmd),

        .transmit, .transmit_and_display => resp: {
            // If we're transmitting, then our `q` setting value is complicated.
            // The `q` setting inherits the value from the starting command
            // unless `q` is set >= 1 on this command. If it is, then we save
            // that as the new `q` setting.
            const storage = &terminal.screens.active.kitty_images;
            if (storage.loading) |loading| switch (cmd.quiet) {
                // q=0 we use whatever the start command value is
                .no => quiet = loading.quiet,

                // q>=1 we use the new value, but we should already be set to it
                inline .ok, .failures => |tag| {
                    assert(quiet == tag);
                    loading.quiet = tag;
                },
            };

            break :resp transmit(io, alloc, terminal, cmd);
        },

        .transmit_animation_frame,
        .control_animation,
        .compose_animation,
        => .{ .message = "ERROR: unimplemented action" },
    };

    // Handle the quiet settings
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }

        return switch (quiet) {
            .no => if (resp.empty()) null else resp,
            .ok => if (resp.ok()) null else resp,
            .failures => null,
        };
    }

    return null;
}

/// Execute a "query" command.
///
/// This command is used to attempt to load an image and respond with
/// success/error but does not persist any of the command to the terminal
/// state.
fn query(
    io: std.Io,
    alloc: Allocator,
    terminal: *const Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.control.query;

    // Query requires image ID. We can't actually send a response without
    // an image ID either but we return an error and this will be logged
    // downstream.
    if (t.image_id == 0) {
        return .{ .message = "EINVAL: image ID required" };
    }

    // Build a partial response to start
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    // A query must attempt a complete load, then discard the result without
    // changing image storage.
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#querying-support-and-available-transmission-mediums
    const storage = &terminal.screens.active.kitty_images;
    var loading = LoadingImage.init(io, alloc, cmd, storage.image_limits) catch |err| {
        encodeError(&result, err);
        return result;
    };
    defer loading.deinit(alloc);

    var img = loading.complete(alloc) catch |err| {
        encodeError(&result, err);
        return result;
    };
    img.deinit(alloc);

    return result;
}

/// Transmit image data.
///
/// This loads the image, validates it, and puts it into the terminal
/// screen storage. It does not display the image.
fn transmit(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;
    var result: Response = if (storage.loading) |loading|
        loading.response
    else
        .{
            .id = t.image_id,
            .image_number = t.image_number,
            .placement_id = t.placement_id,
        };

    const load = loadAndAddImage(io, alloc, terminal, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    errdefer load.image.deinit(alloc);

    // If we're also displaying, then do that now. This function does
    // both transmit and transmit and display. The display might also be
    // deferred if it is multi-chunk.
    if (load.display) |d| {
        assert(!load.more);
        var d_copy = d;
        d_copy.image_id = load.image.id;
        result = display(io, alloc, terminal, &.{
            .control = .{ .display = d_copy },
            .quiet = cmd.quiet,
        });
    }

    // If there are more chunks expected we do not respond.
    if (load.more) return .{};

    // If the loaded image was assigned its ID automatically, not based
    // on a number or explicitly specified ID, then we don't respond.
    if (load.image.metadata.implicit_id) return .{};

    // After the image is added, set the ID in case it changed.
    // The resulting image number and placement ID never change.
    result.id = load.image.id;

    return result;
}

/// Display a previously transmitted image.
fn display(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const d = cmd.display().?;

    // Display requires image ID or number.
    if (d.image_id == 0 and d.image_number == 0) {
        return .{ .message = "EINVAL: image ID or number required" };
    }

    // Build up our response
    var result: Response = .{
        .id = d.image_id,
        .image_number = d.image_number,
        .placement_id = d.placement_id,
    };

    // A virtual placement (U=1) cannot also be a relative placement.
    // Kitty checks this before even looking up the image.
    if (d.virtual_placement and d.parent_id > 0) {
        result.message = "EINVAL: virtual placement cannot refer to a parent";
        return result;
    }

    // Verify the requested image exists if we have an ID
    const storage = &terminal.screens.active.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "ENOENT: image not found";
        return result;
    };

    // Make sure our response has the image id in case we looked up by number
    result.id = img.id;

    // Location where the placement will go.
    const location: ImageStorage.Placement.Location = location: {
        // Virtual placements are not tracked
        if (d.virtual_placement) break :location .virtual;

        // No parent reference (P=): the placement is pinned to the
        // cursor. The cursor is always tracked but we don't want
        // this pin to move with the cursor.
        if (d.parent_id == 0) {
            const pin = terminal.screens.active.pages.trackPin(
                terminal.screens.active.cursor.page_pin.*,
            ) catch |err| {
                log.warn("failed to create pin for Kitty graphics err={}", .{err});
                result.message = "EINVAL: failed to prepare terminal state";
                return result;
            };
            break :location .{ .pin = pin };
        }

        // A parent reference makes this a relative placement: it is
        // positioned relative to the parent placement instead of the
        // cursor.

        // The key of the placement being created, when it is
        // addressable (an explicit placement ID). Needed for
        // self-parent and cycle detection.
        const child: ?ImageStorage.PlacementKey = if (d.placement_id > 0) .{
            .image_id = img.id,
            .placement_id = .{ .tag = .external, .id = d.placement_id },
        } else null;

        const parent = storage.resolveParent(
            io,
            terminal.screens.active,
            child,
            d.parent_id,
            d.parent_placement_id,
        ) catch |err| {
            result.message = switch (err) {
                error.ParentImageNotFound => "ENOPARENT: parent image not found",
                error.ParentPlacementNotFound => "ENOPARENT: parent placement not found",
                error.SelfParent => "EINVAL: placement cannot be its own parent",
                error.Cycle => "ECYCLE: parent chain creates a cycle",
                error.TooDeep => "ETOODEEP: parent chain too deep",
                error.AncestorNotFound => "ENOENT: parent chain ancestor not found",
            };
            return result;
        };

        break :location .{ .relative = .{
            .parent = parent,
            .horizontal_offset = d.horizontal_offset,
            .vertical_offset = d.vertical_offset,
        } };
    };

    // Add the placement
    const p: ImageStorage.Placement = placement: {
        var p: ImageStorage.Placement = .{
            .location = location,
            .x_offset = d.x_offset,
            .y_offset = d.y_offset,
            .source_x = d.x,
            .source_y = d.y,
            .source_width = d.width,
            .source_height = d.height,
            .columns = d.columns,
            .rows = d.rows,
            .z = d.z,
        };

        const cell_offset = p.cellOffset(terminal);
        if (terminal.width_px / terminal.cols > 0) p.x_offset = cell_offset.x;
        if (terminal.height_px / terminal.rows > 0) p.y_offset = cell_offset.y;

        break :placement p;
    };
    storage.addPlacement(
        io,
        alloc,
        terminal.screens.active,
        img.id,
        result.placement_id,
        p,
    ) catch |err| {
        p.deinit(terminal.screens.active);
        encodeError(&result, err);
        return result;
    };

    // Apply cursor movement setting. This only applies to pin placements:
    // relative placements never move the cursor regardless of C=, just
    // like kitty.
    switch (p.location) {
        .virtual, .relative => {},
        .pin => |pin| switch (d.cursor_movement) {
            .none => {},
            .after => {
                // We use terminal.index to properly handle scroll regions.
                const screen = terminal.screens.active;
                const size = p.gridSize(img, terminal);
                const target_x = @as(usize, pin.x) +| @as(usize, size.cols);
                const wraps = target_x >= @as(usize, terminal.cols);
                const requested_rows =
                    (@as(usize, size.rows) -| 1) +| @intFromBool(wraps);

                // The requested row count comes from the application and can
                // be as large as u32. Calling terminal.index once for every
                // row could therefore leave the terminal unresponsive for a
                // very long time.
                //
                // First allow enough calls to reach the bottom of the scroll
                // region. Each call after that scrolls the region by one row,
                // so limit those extra calls to one screen. This follows
                // Kitty's behavior while keeping the amount of work bounded.
                const region = terminal.scrolling_region;
                const rows_before_scroll: usize = if (screen.cursor.y >= region.top and
                    screen.cursor.y <= region.bottom and
                    screen.cursor.x >= region.left and
                    screen.cursor.x <= region.right)
                    @as(usize, region.bottom - screen.cursor.y)
                else
                    0;
                const rows_to_move: usize = @min(
                    requested_rows,
                    rows_before_scroll +| @as(usize, terminal.rows),
                );
                for (0..rows_to_move) |_| terminal.index() catch |err| {
                    log.warn("failed to move cursor: {}", .{err});
                    break;
                };

                // Kitty wraps once when the movement reaches the right edge;
                // otherwise it leaves the cursor immediately to the right of
                // the placement.
                screen.cursor.pending_wrap = false;
                screen.cursorHorizontalAbsolute(
                    if (wraps) 0 else @intCast(target_x),
                );
            },
        },
    }

    return result;
}

/// Display a previously transmitted image.
fn delete(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;

    // Every delete command aborts an incomplete chunked upload.
    if (storage.loading) |loading| {
        loading.destroy(alloc);
        storage.loading = null;
    }

    // Then perform the actual deletion request, too.
    storage.delete(
        io,
        alloc,
        terminal,
        cmd.control.delete.action,
    );

    // Delete never responds on success
    return .{};
}

fn loadAndAddImage(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) !struct {
    image: Image,
    more: bool = false,
    display: ?command.Display = null,
} {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;

    // Determine our image. This also handles chunking and early exit.
    var loading: LoadingImage = if (storage.loading) |loading| loading: {
        // Note: we do NOT want to call "cmd.toOwnedData" here because
        // we're _copying_ the data. We want the command data to be freed.
        try loading.addData(alloc, cmd.data);

        // If we have more then we're done
        if (t.more_chunks) return .{ .image = loading.image, .more = true };

        // We have no more chunks. We're going to be completing the
        // image so we want to destroy the pointer to the loading
        // image and copy it out.
        defer {
            alloc.destroy(loading);
            storage.loading = null;
        }

        break :loading loading.*;
    } else loading: {
        // Reusing a specific image ID deletes the old image and all of its
        // placements when the new transmission begins, not when it completes.
        if (t.image_id > 0) {
            storage.delete(io, alloc, terminal, .{ .id = .{
                .image_id = t.image_id,
                .delete = true,
            } });
        }

        break :loading try .init(io, alloc, cmd, storage.image_limits);
    };

    // We only want to deinit on error. If we're chunking, then we don't
    // want to deinit at all. If we're not chunking, then we'll deinit
    // after we've copied the image out.
    errdefer loading.deinit(alloc);

    // If the image has no ID, we assign one
    if (loading.image.id == 0) {
        if (loading.image.number > 0) {
            loading.image.id = storage.nextImageId(.explicit);
        } else {
            loading.image.id = storage.nextImageId(.implicit);
            loading.image.metadata.implicit_id = true;
        }
    }

    // If this is chunked, this is the beginning of a new chunked transmission.
    // (We checked for an in-progress chunk above.)
    if (t.more_chunks) {
        // We allocate the pointer on the heap because its rare and we
        // don't want to always pay the memory cost to keep it around.
        const loading_ptr = try alloc.create(LoadingImage);
        errdefer alloc.destroy(loading_ptr);
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{ .image = loading.image, .more = true };
    }

    // Dump the image data before it is decompressed
    // loading.debugDump() catch unreachable;

    // Validate and store our image
    var img = try loading.complete(alloc);
    errdefer img.deinit(alloc);
    try storage.addImage(io, alloc, terminal.screens.active, img);

    // Get our display settings
    const display_ = loading.display;

    // Ensure we deinit the loading state because we're done. The image
    // won't be deinit because of "complete" above.
    loading.deinit(alloc);

    return .{ .image = img, .display = display_ };
}

const EncodeableError = Image.Error || Allocator.Error;

/// Encode an error code into a message for a response.
fn encodeError(r: *Response, err: EncodeableError) void {
    switch (err) {
        error.OutOfMemory => r.message = "ENOMEM: out of memory",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.FilePathTooLong => r.message = "EINVAL: file path too long",
        error.TemporaryFileNotInTempDir => r.message = "EINVAL: temporary file not in temp dir",
        error.TemporaryFileNotNamedCorrectly => r.message = "EINVAL: temporary file not named correctly",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.UnsupportedDepth => r.message = "EINVAL: unsupported pixel depth",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}

test "kittygfx query validates image data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);

    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        // A 1x1 RGB image requires three bytes.
        .data = try alloc.dupe(u8, &.{ 0, 0 }),
    };
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        terminal.screens.active.kitty_images.images.count(),
    );
}

test "kittygfx valid query does not replace or store image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    const storage = &terminal.screens.active.kitty_images;

    // Store a red pixel under the same ID used by the query.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=31;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &terminal, &cmd).?.ok());
    }

    // Successfully validate a black pixel without replacing the red one.
    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, &.{ 0, 0, 0 }),
    };
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), storage.images.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(31).?.data.bytes().?,
    );
}

test "kittygfx image id and number are mutually exclusive for every action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const inputs = [_][]const u8{
        "a=q,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=t,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=T,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=p,i=1,I=2,p=3",
        "a=d,d=a,i=1,I=2,p=3",
        "a=f,i=1,I=2,p=3;AAAA",
        "a=a,i=1,I=2,p=3",
        "a=c,i=1,I=2,p=3",
    };

    for (inputs) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);

        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 3), resp.placement_id);
        try testing.expectEqualStrings(
            "EINVAL: image ID and number are mutually exclusive",
            resp.message,
        );

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=2,p=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
            writer.buffered(),
        );
    }

    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.images.count());
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.placements.count());
}

test "kittygfx conflicting identifiers are rejected before mutation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Store an image so a buggy put would succeed and mutate placement state.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Directly constructed commands must receive the same validation as
    // commands produced by the parser.
    {
        const cmd: Command = .{ .control = .{ .display = .{
            .image_id = 1,
            .image_number = 2,
            .placement_id = 7,
            .cursor_movement = .none,
        } } };
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqual(@as(usize, 0), storage.placements.count());
    }

    // Add a real placement so a buggy delete would remove it.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    // q=2 suppresses the required error response but not the validation.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7,q=2",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
}

test "kittygfx chunked success response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,I=93,p=7,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;

        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 93), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=93,p=7;OK\x1b\\",
            writer.buffered(),
        );
    }
}

test "kittygfx chunked error response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=41,p=7,m=1;AA==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AA==");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;

        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 41), resp.id);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    }
}

test "kittygfx more chunks with q=1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=1
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=1,s=1,v=2,c=10,r=1,m=1,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q but should respect initial
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx more chunks with q=0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q so should respond OK
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
}

test "kittygfx more chunks with chunk increasing q" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk sets q=1 so should not respond
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx delete aborts chunked image load" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Begin a two-chunk RGB image, then interrupt it with a delete.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);

    {
        const cmd = try command.Parser.parseString(alloc, "a=d");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading == null);

    // A fresh chunked upload must start from empty state after the delete.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 6), storage.imageById(1).?.data.len());
}

test "kittygfx uppercase id delete preserves image when placement does not match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Store an unplaced 1x1 RGB image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Uppercase deletion may free data only if the named placement matched.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=I,i=1,p=7",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    try testing.expect(storage.imageById(1) != null);
}

test "kittygfx default format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}

test "kittygfx test valid u32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=4294967295",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx test valid i32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=1,z=-2147483648",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx no response with no image ID or number" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx no response with no image ID or number load and display" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx retransmit same id gets fresh image generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Transmit a 1x2 RGB image with id=1.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;
    try testing.expect(gen1 > 0);
    try testing.expectEqual(gen1, storage.generation);

    // Retransmit the same id with identical dimensions/length. The
    // (width, height, format, len) tuple is identical, so only the
    // generation can reveal that the contents were replaced.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, storage.generation);
}

test "kittygfx retransmit same id removes existing placements" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();

    // Transmit and display an image, then add anonymous and named placements.
    // Multiple anonymous a=p placements for one image are explicitly valid.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
    try testing.expectEqual(
        tracked + 3,
        t.screens.active.pages.countTrackedPins(),
    );

    // Retransmitting replaces the image and must delete every old placement.
    // Plain a=t creates no replacement placement of its own.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());

    // a=T creates one new placement after deleting the previous image and
    // placements, so repeated redraws remain bounded at one placement.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
}

test "kittygfx retransmit same id removes image on first chunk" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();

    // Store and display the old image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expect(storage.imageById(1) != null);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );

    // Starting a replacement for the same explicit ID removes the old image
    // and placements before the replacement's final chunk arrives.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "kittygfx delete then retransmit same id gets fresh generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Transmit and display, then delete everything (including image
    // data), then retransmit the same ID.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,c=1,r=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;

    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=A");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    try testing.expect(storage.imageById(1) == null);
    const gen_delete = storage.generation;
    try testing.expect(gen_delete > gen1);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expect(gen2 > gen_delete);
}

test "kittygfx display clamps cell offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=2,r=1,X=99,Y=99,C=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const placement = it.next().?.value_ptr;
    try testing.expectEqual(@as(u32, 9), placement.x_offset);
    try testing.expectEqual(@as(u32, 19), placement.y_offset);

    const actual = placement.pixelSize(storage.imageById(1).?, &t);
    try testing.expectEqual(@as(u32, 11), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}

test "kittygfx placement bounds cursor movement for untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=4294967295;////",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), t.screens.active.kitty_images.placements.count());
    // Reaching the bottom takes four rows, then scrolling is capped to one
    // screen (five rows), matching Kitty's bounded screen-scroll behavior.
    try testing.expectEqual(@as(usize, 10), t.screens.active.pages.scrollbar().total);
}

test "kittygfx placement moves cursor past a tall image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Load a one-pixel RGB image, then place it over the full width and eight
    // rows. Eight rows are taller than the screen but still within Kitty's
    // scroll budget.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,c=5,r=8",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }

    // A subsequent placement begins immediately after the first one instead
    // of overlapping it at the old one-screen movement cap.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=2,C=1",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }

    const storage = &t.screens.active.kitty_images;
    const first = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const second = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const first_pin = switch (first.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const second_pin = switch (second.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const first_y = t.screens.active.pages.pointFromPin(
        .screen,
        first_pin.*,
    ).?.screen.y;
    const second_y = t.screens.active.pages.pointFromPin(
        .screen,
        second_pin.*,
    ).?.screen.y;
    try testing.expectEqual(first_y + 8, second_y);
}

test "kittygfx unknown format responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        t.screens.active.kitty_images.images.count(),
    );
}

test "kittygfx unknown format on query responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=q,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
}

test "kittygfx zero format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Kitty treats f=0 as an absent f, i.e. RGBA.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=0,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);

    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const img = t.screens.active.kitty_images.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}

test "kittygfx unknown format with q=3 has no response" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // q above 2 is out of range in the spec but Kitty suppresses
    // everything for anything above 1, so we must still parse it.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,q=3,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);

    try testing.expect(execute(io, alloc, &t, &cmd) == null);
}

test "kittygfx out of range display keys are tolerated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=31,s=1,v=1,C=2,U=2;AAAA",
        );
        defer cmd.deinit(alloc);

        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 31), resp.id);
    }

    // U=2 must behave like U=1, so the placement is virtual.
    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const entry = it.next().?;
    try testing.expect(entry.value_ptr.location == .virtual);
}

test "kittygfx number-based transmission assigns smallest free id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Empty storage: the first free ID is 1, as in Kitty.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 42), resp.image_number);
    }

    // Occupy ID 2 explicitly; the next number gets 3.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=43;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 3), resp.id);
    }

    // Deleting ID 1 opens a gap that the next number fills.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=44;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }

    try testing.expectEqual(@as(usize, 3), storage.images.count());
    try testing.expectEqual(@as(u32, 44), storage.imageById(1).?.number);
    try testing.expectEqual(@as(u32, 0), storage.imageById(2).?.number);
    try testing.expectEqual(@as(u32, 43), storage.imageById(3).?.number);
}

test "kittygfx number-based id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // A client stores and places a red pixel on the ID the old wrapping
    // counter would assign first.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // A number-based transmission must not collide with it.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;AAD/",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }

    // The client's image and placement are untouched.
    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
}

test "kittygfx implicit id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // A client stores and places a red pixel on the ID the implicit
    // counter assigns first.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Transmit without an ID or number: no response, and the counter
    // skips over the in-use ID instead of replacing that image.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }

    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
    const implicit = storage.imageById(2147483648).?;
    try testing.expect(implicit.metadata.implicit_id);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, implicit.data.bytes().?);
}

test "kittygfx relative placement with missing parent image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent image does not exist: the placement must be rejected
    // with ENOPARENT, nothing may be created, and the cursor must not
    // move (a relative placement never moves the cursor, and a failed
    // one certainly must not).
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,P=42,Q=1,H=2,V=2",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent image not found",
            resp.message,
        );
    }

    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
}

test "kittygfx relative placement with missing parent placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent image exists but has no placements at all.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }

    // The parent image has a placement, but not the requested one.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2,p=1,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }

    try testing.expectEqual(@as(usize, 1), storage.placements.count());
}

test "kittygfx relative placement cannot parent itself" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Explicitly via Q, and implicitly when the Q=0 fallback selects
    // the placement being replaced.
    for ([_][]const u8{
        "a=p,i=1,p=1,P=1,Q=1",
        "a=p,i=1,p=1,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "EINVAL: placement cannot be its own parent",
            resp.message,
        );
    }

    // The original placement must be untouched.
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}

test "kittygfx relative placement cycle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Replacing placement 1 with a parent of placement 2 would create
    // the cycle 1 -> 2 -> 1.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=1,P=1,Q=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ECYCLE: parent chain creates a cycle",
            resp.message,
        );
    }

    // The original placement must be untouched, keeping the stored
    // chains acyclic.
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}

test "kittygfx relative placement chain depth limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // Chains of up to parent_chain_limit (8) links must work: these
    // placements form the chain 9 -> 8 -> ... -> 2 -> 1.
    for (2..10) |id| {
        var buf: [64]u8 = undefined;
        const cmd = try command.Parser.parseString(
            alloc,
            try std.fmt.bufPrint(&buf, "a=p,i=1,p={},P=1,Q={}", .{ id, id - 1 }),
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // One more link exceeds the limit.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=10,P=1,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ETOODEEP: parent chain too deep",
            resp.message,
        );
    }

    const storage = &t.screens.active.kitty_images;
    try testing.expectEqual(@as(usize, 9), storage.placements.count());
}

test "kittygfx relative placement does not move cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // C is left at its default (move after) on the relative placement
    // but it must never move the cursor.
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1,H=3,V=2,c=2,r=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);

    // The stored placement carries the parent link and offsets.
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const rel = p.location.relative;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(@as(i32, 3), rel.horizontal_offset);
    try testing.expectEqual(@as(i32, 2), rel.vertical_offset);
}

test "kittygfx virtual placement with parent rejected before image lookup" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Kitty rejects U=1 + P= before checking that the image exists,
    // so this must not be ENOENT.
    const cmd = try command.Parser.parseString(alloc, "a=p,i=42,U=1,P=1");
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqualStrings(
        "EINVAL: virtual placement cannot refer to a parent",
        resp.message,
    );
}

test "kittygfx deleting a parent deletes relative placements transitively" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Root (pin) <- child <- grandchild
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());

    // Deleting the middle placement takes the grandchild with it but
    // leaves the root.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=2");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expect(storage.placements.contains(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));

    // Deleting the root removes the remaining placement, and the
    // image itself is retained (lowercase delete).
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) != null);
}

test "kittygfx retransmitting parent image deletes relative placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Image 2's placement is relative to image 1's placement.
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=2,p=1,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 2), storage.placements.count());

    // Retransmitting image 1 removes its placements, which orphans
    // and removes image 2's placement too. Image 2 is left without
    // any placement so it is freed as well: retransmission deletes
    // with uppercase semantics, and kitty also removes an image whose
    // last placement died from a broken parent chain.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(2) == null);
}

test "kittygfx relative placement parent fallback picks lowest external id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=7,C=1",
        "a=p,i=1,p=3,C=1",
        "a=p,i=2,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    var it = storage.placements.iterator();
    const rel = while (it.next()) |entry| {
        if (entry.key_ptr.image_id == 2) break entry.value_ptr.location.relative;
    } else return error.PlacementNotFound;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }));
}

test "kittygfx placements created after a full reset are retained" {
    // Regression test: Screen.reset reuses the cursor's tracked pin
    // but PageList.reset marked it garbage. Placements copy the cursor
    // pin, so every placement created after a reset was born garbage
    // and silently swept by the next placement command.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 24, .cols = 80 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    t.fullReset();

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,C=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
}

test "kittygfx relative placement with pruned parent is ENOPARENT" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The parent's tracked content is pruned from history but the
    // placement hasn't been swept yet. The put must reap it and answer
    // ENOPARENT rather than storing an orphan against it.
    const parent = storage.placements.getPtr(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    parent.location.pin.garbage = true;

    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=2,P=1,Q=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "kittygfx uppercase delete frees image of cascaded placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }

    // The uppercase delete only matches placement 1. The cascade
    // removes placement 2, leaving the image without placements, so
    // the image must be freed too.
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) == null);
}
