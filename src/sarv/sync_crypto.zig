//! Encrypted-settings-sync crypto + manifest — the portable Zig port of the
//! macOS SyncCrypto.swift and SyncManifest.swift. Must be byte-compatible with
//! the macOS app so sync works cross-platform (see SCHEMA.md §7 and §8).
//!
//! The master password never leaves the device; a 256-bit key is derived from
//! it with PBKDF2-HMAC-SHA256 (a random per-vault salt lives in the plaintext
//! manifest) and each payload is encrypted with AES-256-GCM. GCM's auth tag is
//! what detects a wrong master password on another machine: decryption fails
//! rather than yielding garbage.
//!
//! Unlike envelope.zig (the at-rest wrapper), sync payloads are the *raw*
//! AES-256-GCM combined bytes (nonce ‖ ciphertext ‖ tag) with NO JSON envelope,
//! matching CryptoKit's `AES.GCM.SealedBox.combined`.

const std = @import("std");
const model = @import("model.zig");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// PBKDF2 work factor. High enough to be costly to brute-force, low enough to
/// run in well under a second on a manual push/pull.
pub const pbkdf2_iterations: u32 = 310_000;
pub const salt_len = 16;
pub const key_len = 32; // AES-256
pub const nonce_len = Aes256Gcm.nonce_length; // 12
pub const tag_len = Aes256Gcm.tag_length; // 16

/// AES-GCM encryption of this literal proves the master password is correct.
pub const verifier_token = "sarv-sync-verifier-v1";

/// Derive the AES key from the master password + salt via PBKDF2-HMAC-SHA256.
/// Deterministic for a given (password, salt, iterations).
pub fn deriveKey(password: []const u8, salt: []const u8, iterations: u32) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    // Zig's pbkdf2 only errors when the derived length exceeds the PRF limit;
    // key_len (32) is always in range, so this cannot fail here.
    std.crypto.pwhash.pbkdf2(&out, password, salt, iterations, HmacSha256) catch unreachable;
    return out;
}

/// Encrypt `plaintext` with AES-256-GCM into raw combined bytes
/// (nonce(12) ‖ ciphertext ‖ tag(16)). NO JSON envelope. Caller owns the result.
pub fn seal(alloc: std.mem.Allocator, key: [key_len]u8, plaintext: []const u8) ![]u8 {
    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const combined = try alloc.alloc(u8, nonce_len + plaintext.len + tag_len);
    errdefer alloc.free(combined);
    @memcpy(combined[0..nonce_len], &nonce);

    var tag: [tag_len]u8 = undefined;
    Aes256Gcm.encrypt(
        combined[nonce_len .. nonce_len + plaintext.len],
        &tag,
        plaintext,
        "",
        nonce,
        key,
    );
    @memcpy(combined[nonce_len + plaintext.len ..], &tag);
    return combined;
}

pub const OpenError = error{
    Malformed,
    AuthenticationFailed,
    OutOfMemory,
};

/// Decrypt raw combined AES-256-GCM bytes back to plaintext. Caller owns the
/// result. AuthenticationFailed means a wrong key or tampered data.
pub fn open(alloc: std.mem.Allocator, key: [key_len]u8, combined: []const u8) OpenError![]u8 {
    if (combined.len < nonce_len + tag_len) return error.Malformed;

    const nonce: [nonce_len]u8 = combined[0..nonce_len].*;
    const ct = combined[nonce_len .. combined.len - tag_len];
    const tag: [tag_len]u8 = combined[combined.len - tag_len ..][0..tag_len].*;

    const plaintext = try alloc.alloc(u8, ct.len);
    errdefer alloc.free(plaintext);
    Aes256Gcm.decrypt(plaintext, ct, tag, "", nonce, key) catch
        return error.AuthenticationFailed;
    return plaintext;
}

/// Seal the verifier token and base64-encode it for the manifest. Caller owns
/// the returned base64 string.
pub fn makeVerifier(alloc: std.mem.Allocator, key: [key_len]u8) ![]u8 {
    const combined = try seal(alloc, key, verifier_token);
    defer alloc.free(combined);
    return encodeBase64(alloc, combined);
}

/// Decrypt the base64 verifier from a manifest and confirm it matches the
/// literal token — i.e. the derived key (and thus the password) is correct.
pub fn verifyPassword(alloc: std.mem.Allocator, key: [key_len]u8, verifier_b64: []const u8) bool {
    const combined = decodeBase64(alloc, verifier_b64) catch return false;
    defer alloc.free(combined);
    const plaintext = open(alloc, key, combined) catch return false;
    defer alloc.free(plaintext);
    return std.mem.eql(u8, plaintext, verifier_token);
}

/// Standard-alphabet base64 encode. Caller owns the result.
pub fn encodeBase64(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(bytes.len));
    errdefer alloc.free(out);
    _ = enc.encode(out, bytes);
    return out;
}

/// Standard-alphabet base64 decode. Caller owns the result.
pub fn decodeBase64(alloc: std.mem.Allocator, b64: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const len = try dec.calcSizeForSlice(b64);
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    try dec.decode(out, b64);
    return out;
}

/// Plaintext `manifest.json` at the root of the remote (SCHEMA.md §7). Carries
/// everything needed to show sync status without decrypting and to derive the
/// key + validate the master password on another machine. Nothing secret lives
/// here: the salt is public by design, and `verifier` only *confirms* the
/// password — it can't reveal it.
///
/// Field names ARE the JSON keys. Swift encodes `Data` (kdfSalt, verifier) as
/// base64 strings, so both are represented here as base64 `[]const u8` — the
/// base64 is done by the caller via encodeBase64 / decodeBase64.
pub const SyncManifest = struct {
    /// On-disk format version, for future migrations.
    schema: i64 = 1,
    /// Monotonically increasing; bumped on every push. Drives "remote is newer".
    version: i64,
    lastSyncDate: []const u8,
    /// Human label for "last pushed from <device>".
    deviceName: []const u8,
    /// PBKDF2 salt, base64 (16 raw bytes). Public by design.
    kdfSalt: []const u8,
    kdfIterations: i64,
    /// AES-GCM-combined of `verifier_token`, base64.
    verifier: []const u8,
    /// Names of the encrypted payload files this manifest describes.
    files: []const []const u8,
};

/// Decrypted contents of `hosts.enc` (SCHEMA.md §8).
pub const SyncHostsPayload = struct {
    hosts: []const model.SavedHost,
    groups: []const model.HostGroup,
    /// Optional for back-compat with older payloads.
    snippets: ?[]const model.Snippet = null,
};

/// Decrypted contents of `settings.enc` (SCHEMA.md §8). Every field is optional
/// so only values that were actually set get serialized — never blanks that
/// could clobber a populated value on the receiving machine. Serialize with
/// `emit_null_optional_fields = false`.
/// A background image carried across machines (SCHEMA.md §8): original file
/// name + base64-encoded bytes.
pub const BackgroundImageBlob = struct {
    name: []const u8,
    /// Image bytes, base64-encoded (Swift encodes Data as base64 in JSON).
    data: []const u8,
};

pub const SyncSettingsPayload = struct {
    ghosttyConfig: ?[]const u8 = null,
    bgShared: ?bool = null,
    bgImagePath: ?[]const u8 = null,
    bgVisibility: ?f64 = null,
    /// App-level keybinds: action → list of key strings.
    appKeybinds: ?std.json.ArrayHashMap([]const []const u8) = null,
    sftpAutoSave: ?bool = null,
    sftpConfirmDelete: ?bool = null,
    sftpShowHidden: ?bool = null,
    backgroundImage: ?BackgroundImageBlob = null,
};

/// Parse options for payloads/manifests: ignore unknown fields so newer files
/// from the other platform never break older readers.
pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

/// Serialize `value` to JSON. Caller owns the result. Matches the writer-based
/// stringify pattern used elsewhere in this data layer (store.zig).
pub fn toJson(alloc: std.mem.Allocator, value: anytype, options: std.json.Stringify.Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer, .options = options };
    try jws.write(value);
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sarv: deriveKey is deterministic and salt-sensitive" {
    const salt_a = "0123456789abcdef";
    const salt_b = "fedcba9876543210";
    const iters: u32 = 1000;

    const k1 = deriveKey("hunter2", salt_a, iters);
    const k2 = deriveKey("hunter2", salt_a, iters);
    try std.testing.expectEqualSlices(u8, &k1, &k2);

    const k3 = deriveKey("hunter2", salt_b, iters);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k3));
}

test "sarv: seal/open round-trip" {
    const alloc = std.testing.allocator;
    const key = deriveKey("pw", "0123456789abcdef", 1000);

    const secret = "{\"hosts\":[],\"groups\":[]}";
    const sealed = try seal(alloc, key, secret);
    defer alloc.free(sealed);
    // Raw combined layout: nonce ‖ ct ‖ tag, no JSON envelope.
    try std.testing.expectEqual(nonce_len + secret.len + tag_len, sealed.len);

    const opened = try open(alloc, key, sealed);
    defer alloc.free(opened);
    try std.testing.expectEqualStrings(secret, opened);
}

test "sarv: open with wrong key fails authentication" {
    const alloc = std.testing.allocator;
    const key = deriveKey("pw", "0123456789abcdef", 1000);
    const sealed = try seal(alloc, key, "secret");
    defer alloc.free(sealed);

    var wrong = key;
    wrong[0] +%= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(alloc, wrong, sealed));
}

test "sarv: makeVerifier then verifyPassword" {
    const alloc = std.testing.allocator;
    const salt = "0123456789abcdef";
    const correct = deriveKey("correct horse", salt, 1000);

    const verifier = try makeVerifier(alloc, correct);
    defer alloc.free(verifier);

    try std.testing.expect(verifyPassword(alloc, correct, verifier));

    const wrong = deriveKey("wrong password", salt, 1000);
    try std.testing.expect(!verifyPassword(alloc, wrong, verifier));
}

test "sarv: SyncManifest JSON round-trip preserves fields" {
    const alloc = std.testing.allocator;
    const original: SyncManifest = .{
        .schema = 1,
        .version = 7,
        .lastSyncDate = "2026-07-03T12:00:00Z",
        .deviceName = "MacBook Pro",
        .kdfSalt = "MDEyMzQ1Njc4OWFiY2RlZg==",
        .kdfIterations = 310_000,
        .verifier = "dmVyaWZpZXItYmxvYg==",
        .files = &.{ "hosts.enc", "settings.enc" },
    };

    // Serialize.
    const json = try toJson(alloc, original, .{});
    defer alloc.free(json);

    // The exact JSON keys must appear (the cross-platform contract).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kdfIterations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kdfSalt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verifier\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"files\"") != null);

    // Parse back and confirm fields survive.
    const parsed = try std.json.parseFromSlice(SyncManifest, alloc, json, parse_options);
    defer parsed.deinit();
    const m = parsed.value;
    try std.testing.expectEqual(@as(i64, 1), m.schema);
    try std.testing.expectEqual(@as(i64, 7), m.version);
    try std.testing.expectEqual(@as(i64, 310_000), m.kdfIterations);
    try std.testing.expectEqualStrings("2026-07-03T12:00:00Z", m.lastSyncDate);
    try std.testing.expectEqualStrings("MacBook Pro", m.deviceName);
    try std.testing.expectEqualStrings(original.kdfSalt, m.kdfSalt);
    try std.testing.expectEqualStrings(original.verifier, m.verifier);
    try std.testing.expectEqual(@as(usize, 2), m.files.len);
    try std.testing.expectEqualStrings("hosts.enc", m.files[0]);
    try std.testing.expectEqualStrings("settings.enc", m.files[1]);
}

test "sarv: SyncSettingsPayload omits null optional fields" {
    const alloc = std.testing.allocator;
    const payload: SyncSettingsPayload = .{ .bgShared = true, .sftpShowHidden = false };

    const json = try toJson(alloc, payload, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"bgShared\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sftpShowHidden\"") != null);
    // Unset fields must not be serialized (so they never clobber on pull).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ghosttyConfig\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bgVisibility\"") == null);
}
