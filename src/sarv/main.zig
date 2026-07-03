//! Sarv data layer — the cross-platform (Zig) implementation of the
//! Sarv Terminal feature data: models, JSON stores, at-rest encryption and
//! config paths. This is the foundation the Linux (GTK) Sarv UI builds on;
//! the on-disk formats are shared with the macOS (Swift) app — see SCHEMA.md.

pub const model = @import("model.zig");
pub const paths = @import("paths.zig");
pub const envelope = @import("envelope.zig");
pub const keys = @import("keys.zig");
pub const store = @import("store.zig");
pub const ssh = @import("ssh.zig");
pub const askpass = @import("askpass.zig");
pub const vault = @import("vault.zig");
pub const util = @import("util.zig");

pub const SavedHost = model.SavedHost;
pub const HostGroup = model.HostGroup;
pub const Snippet = model.Snippet;
pub const PortForward = model.PortForward;
pub const ActivityEntry = model.ActivityEntry;

test {
    _ = model;
    _ = paths;
    _ = envelope;
    _ = keys;
    _ = store;
    _ = ssh;
    _ = askpass;
    _ = vault;
    _ = util;
}
