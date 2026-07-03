//! SarvEncEnvelope — the at-rest encryption wrapper shared with macOS
//! (LocalDataCrypto.swift). Encrypted data files are a small JSON envelope:
//!
//!   { "sarvEnc": 1, "blob": "<base64(nonce ‖ ciphertext ‖ tag)>" }
//!
//! AES-256-GCM in CryptoKit's "combined" layout: 12-byte nonce, ciphertext,
//! 16-byte tag. Where the 256-bit data key comes from is platform-specific
//! (Secure Enclave on macOS, Secret Service/file keystore on Linux — see
//! keys.zig); this file only seals and opens.

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const version = 1;
pub const key_len = Aes256Gcm.key_length; // 32
pub const nonce_len = Aes256Gcm.nonce_length; // 12
pub const tag_len = Aes256Gcm.tag_length; // 16

const Envelope = struct {
    sarvEnc: i64,
    blob: []const u8,
};

/// Quick structural check: does this file content look like an envelope?
/// Plaintext legacy files (JSON arrays) and foreign JSON return false.
pub fn isEnvelope(alloc: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(
        Envelope,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return false;
    defer parsed.deinit();
    return parsed.value.sarvEnc == version;
}

/// Encrypt plaintext into a serialized envelope. Caller owns the result.
pub fn seal(
    alloc: std.mem.Allocator,
    key: [Aes256Gcm.key_length]u8,
    plaintext: []const u8,
) ![]u8 {
    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const combined = try alloc.alloc(u8, nonce_len + plaintext.len + tag_len);
    defer alloc.free(combined);
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

    const b64 = std.base64.standard.Encoder;
    const blob = try alloc.alloc(u8, b64.calcSize(combined.len));
    defer alloc.free(blob);
    _ = b64.encode(blob, combined);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    try jws.write(Envelope{ .sarvEnc = version, .blob = blob });
    return try out.toOwnedSlice();
}

pub const OpenError = error{
    NotAnEnvelope,
    UnsupportedVersion,
    AuthenticationFailed,
    OutOfMemory,
};

/// Decrypt a serialized envelope back to plaintext. Caller owns the result.
/// AuthenticationFailed means a wrong key or a tampered file.
pub fn open(
    alloc: std.mem.Allocator,
    key: [Aes256Gcm.key_length]u8,
    envelope_bytes: []const u8,
) OpenError![]u8 {
    const parsed = std.json.parseFromSlice(
        Envelope,
        alloc,
        envelope_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.NotAnEnvelope;
    defer parsed.deinit();
    if (parsed.value.sarvEnc != version) return error.UnsupportedVersion;

    const b64 = std.base64.standard.Decoder;
    const combined_len = b64.calcSizeForSlice(parsed.value.blob) catch
        return error.NotAnEnvelope;
    if (combined_len < nonce_len + tag_len) return error.NotAnEnvelope;
    const combined = try alloc.alloc(u8, combined_len);
    defer alloc.free(combined);
    b64.decode(combined, parsed.value.blob) catch return error.NotAnEnvelope;

    const nonce: [nonce_len]u8 = combined[0..nonce_len].*;
    const ct = combined[nonce_len .. combined_len - tag_len];
    const tag: [tag_len]u8 = combined[combined_len - tag_len ..][0..tag_len].*;

    const plaintext = try alloc.alloc(u8, ct.len);
    errdefer alloc.free(plaintext);
    Aes256Gcm.decrypt(plaintext, ct, tag, "", nonce, key) catch
        return error.AuthenticationFailed;
    return plaintext;
}

test "sarv: seal/open round-trip" {
    const alloc = std.testing.allocator;
    var key: [Aes256Gcm.key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const secret = "[{\"id\":\"abc\",\"hostname\":\"10.0.0.1\"}]";
    const sealed = try seal(alloc, key, secret);
    defer alloc.free(sealed);

    try std.testing.expect(isEnvelope(alloc, sealed));

    const opened = try open(alloc, key, sealed);
    defer alloc.free(opened);
    try std.testing.expectEqualStrings(secret, opened);
}

test "sarv: open with wrong key fails authentication" {
    const alloc = std.testing.allocator;
    var key: [Aes256Gcm.key_length]u8 = undefined;
    std.crypto.random.bytes(&key);
    const sealed = try seal(alloc, key, "secret");
    defer alloc.free(sealed);

    var wrong = key;
    wrong[0] +%= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(alloc, wrong, sealed));
}

test "sarv: plaintext JSON array is not detected as an envelope" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!isEnvelope(alloc, "[{\"id\":\"x\"}]"));
    try std.testing.expect(!isEnvelope(alloc, "{\"other\":true}"));
}
