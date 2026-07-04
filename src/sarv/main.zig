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
pub const hostkey = @import("hostkey.zig");
pub const vault = @import("vault.zig");
pub const util = @import("util.zig");
pub const known_hosts = @import("known_hosts.zig");
pub const sshkeys = @import("sshkeys.zig");
pub const portforward = @import("portforward.zig");
pub const shell_history = @import("shell_history.zig");
pub const sftp = @import("sftp.zig");
pub const sync_crypto = @import("sync_crypto.zig");
pub const sync = @import("sync.zig");

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
    _ = hostkey;
    _ = vault;
    _ = util;
    _ = known_hosts;
    _ = sshkeys;
    _ = portforward;
    _ = shell_history;
    _ = sftp;
    _ = sync_crypto;
    _ = sync;
}
