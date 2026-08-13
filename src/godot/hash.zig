//! Godot-compatible hash functions ported from `core/templates/hashfuncs.h` and
//! `core/string/ustring.cpp`.

pub const murmur3_seed: u32 = 0x7F07C65;

/// Godot `String::hash()` — djb2 over UTF-32 code units, 32-bit accumulator.
pub fn hashUtf32(code_units: []const u21) u32 {
    var hashv: u32 = 5381;
    for (code_units) |c| {
        hashv = (hashv << 5) +% hashv +% @as(u32, @truncate(c));
    }
    return hashv;
}

/// Godot `String::hash64()` — djb2 over UTF-32 code units, 64-bit accumulator.
pub fn hash64Utf32(code_units: []const u21) u64 {
    var hashv: u64 = 5381;
    for (code_units) |c| {
        hashv = (hashv << 5) +% hashv +% @as(u64, @truncate(c));
    }
    return hashv;
}

/// `hashUtf32` over raw bytes, each widened to one code unit.
///
/// Equivalent to copying a byte slice into a `[]u21` and calling `hashUtf32`,
/// which is what the ID seeders do, but without a temporary buffer sized to the
/// input — so it cannot fail on long paths.
pub fn hashUtf32Bytes(bytes: []const u8) u32 {
    var hashv: u32 = 5381;
    for (bytes) |c| {
        hashv = (hashv << 5) +% hashv +% @as(u32, c);
    }
    return hashv;
}

/// `hash64Utf32` over raw bytes, each widened to one code unit.
pub fn hash64Utf32Bytes(bytes: []const u8) u64 {
    var hashv: u64 = 5381;
    for (bytes) |c| {
        hashv = (hashv << 5) +% hashv +% @as(u64, c);
    }
    return hashv;
}

test "byte hashes match the widened code-unit path" {
    const cases = [_][]const u8{
        "",
        "res://main.tscn",
        "res://" ++ "a" ** 600 ++ ".tscn", // longer than the old 512-unit buffer
        "res://ünïcødé/scene.tscn",
    };
    for (cases) |bytes| {
        var widened: [1024]u21 = undefined;
        for (bytes, 0..) |c, i| widened[i] = c;
        try std.testing.expectEqual(hashUtf32(widened[0..bytes.len]), hashUtf32Bytes(bytes));
        try std.testing.expectEqual(hash64Utf32(widened[0..bytes.len]), hash64Utf32Bytes(bytes));
    }
}

/// Godot `hash_djb2` for ASCII/UTF-8 bytes (`hash * 33 ^ c`).
pub fn hashDjb2Ascii(bytes: []const u8) u32 {
    var hash: u32 = 5381;
    for (bytes) |c| {
        hash = ((hash << 5) +% hash) ^ c;
    }
    return hash;
}

/// Godot `hash_murmur3_one_32`.
pub fn murmur3One32(input: u32, seed: u32) u32 {
    var value = input;
    value *%= 0xcc9e2d51;
    value = (value << 15) | (value >> 17);
    value *%= 0x1b873593;

    var result = seed ^ value;
    result = (result << 13) | (result >> 19);
    result = result *% 5 +% 0xe6546b64;
    return result;
}

/// Lowercase ASCII in place (Godot `String::to_lower` for resource paths).
pub fn toLowerAscii(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

const std = @import("std");

test "path hash matches Godot reference" {
    const path = "res://test.tscn";
    var code_units: [path.len]u21 = undefined;
    for (path, 0..) |c, i| code_units[i] = c;
    try std.testing.expectEqual(@as(u32, 1290995245), hashUtf32(&code_units));
}

test "murmur3 seed constant" {
    try std.testing.expectEqual(@as(u32, 0x7F07C65), murmur3_seed);
}
