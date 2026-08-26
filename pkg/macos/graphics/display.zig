const c = @import("c.zig").c;

pub const DirectDisplayID = c.CGDirectDisplayID;

/// The display ID that means "no display".
pub const null_display: DirectDisplayID = 0;

/// A summary of what changed about the display configuration. This is a
/// bitfield of `kCGDisplay*Flag` values; see CGDisplayConfiguration.h.
pub const ChangeSummaryFlags = u32;

/// True if this notification is the one CoreGraphics sends *before* it
/// applies a configuration change.
///
/// There is nothing useful to do with the new configuration at this point
/// because it isn't in effect yet, and it is specifically unsafe to call
/// CoreVideo display link APIs from a reconfiguration callback, so callers
/// generally want to ignore these.
pub fn isBeginConfiguration(flags: ChangeSummaryFlags) bool {
    return flags & c.kCGDisplayBeginConfigurationFlag != 0;
}

pub const ReconfigurationCallback = *const fn (
    display: DirectDisplayID,
    flags: ChangeSummaryFlags,
    userinfo: ?*anyopaque,
) callconv(.c) void;

pub const Error = error{
    RegistrationFailed,
};

/// Register a callback to be invoked on the main thread whenever the display
/// configuration changes.
pub fn registerReconfigurationCallback(
    callback: ReconfigurationCallback,
    userinfo: ?*anyopaque,
) Error!void {
    if (c.CGDisplayRegisterReconfigurationCallback(
        @ptrCast(callback),
        userinfo,
    ) != c.kCGErrorSuccess) return Error.RegistrationFailed;
}

/// Remove a callback previously registered with
/// `registerReconfigurationCallback`. The callback and userinfo must both
/// match the values used to register.
pub fn removeReconfigurationCallback(
    callback: ReconfigurationCallback,
    userinfo: ?*anyopaque,
) Error!void {
    if (c.CGDisplayRemoveReconfigurationCallback(
        @ptrCast(callback),
        userinfo,
    ) != c.kCGErrorSuccess) return Error.RegistrationFailed;
}
