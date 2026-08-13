//! Godot `ResourceUID` encoding and deterministic path-based ID generation.
//! Ported from `core/io/resource_uid.cpp`.

const std = @import("std");
const hash = @import("hash.zig");
const pcg = @import("pcg.zig");

pub const invalid_id: i64 = -1;

// Godot keeps these off-by-one for compatibility (GH-83843).
const char_count: u32 = 'z' - 'a';
const base: u32 = char_count + ('9' - '0');

const uuid_characters = [_]u8{
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p',
    'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', '0', '1', '2', '3', '4', '5', '6',
    '7', '8',
};
const uuid_characters_element_count = uuid_characters.len;
const max_uuid_number_length = 13;

pub fn idToText(allocator: std.mem.Allocator, id: i64) ![]u8 {
    if (id < 0) return try allocator.dupe(u8, "uid://<invalid>");

    var value: u64 = @intCast(id);
    var tmp: [max_uuid_number_length]u8 = undefined;
    var tmp_size: usize = 0;

    while (true) {
        const c = value % uuid_characters_element_count;
        tmp[tmp_size] = uuid_characters[c];
        tmp_size += 1;
        value /= uuid_characters_element_count;
        if (value == 0) break;
    }

    const prefix = "uid://";
    const out = try allocator.alloc(u8, prefix.len + tmp_size);
    @memcpy(out[0..prefix.len], prefix);
    for (0..tmp_size) |i| {
        out[prefix.len + i] = tmp[tmp_size - i - 1];
    }
    return out;
}

pub fn textToId(text: []const u8) i64 {
    const prefix = "uid://";
    if (!std.mem.startsWith(u8, text, prefix)) return invalid_id;
    if (std.mem.eql(u8, text, "uid://<invalid>")) return invalid_id;

    var uid: u64 = 0;
    for (text[prefix.len..]) |c| {
        uid *%= base;
        if (c >= 'a' and c <= 'z') {
            uid += c - 'a';
        } else if (c >= '0' and c <= '9') {
            uid += c - '0' + char_count;
        } else {
            return invalid_id;
        }
    }
    return @intCast(uid & 0x7FFFFFFFFFFFFFFF);
}

/// Deterministic UID for a resource path, matching `ResourceUID::create_id_for_path`.
/// `resource_path` is the Godot path (e.g. `res://foo.tscn`). `file_bytes` must be the
/// on-disk file contents used for MD5 (Godot reads the file at that path).
pub fn createIdForPath(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    resource_path: []const u8,
    file_bytes: []const u8,
) !i64 {
    var md5_hex: [32]u8 = undefined;
    try md5HexLower(&md5_hex, file_bytes);

    const lower_path = try hash.toLowerAscii(allocator, resource_path);
    defer allocator.free(lower_path);

    const seed = hashString64(project_name) *%
        hashString64(lower_path) *%
        hashString64(&md5_hex);

    var rng = pcg.Pcg32{};
    rng.seed(seed);

    while (true) {
        const num1: i64 = @intCast(rng.nextU32());
        const num2: i64 = @as(i64, @intCast(rng.nextU32())) << 32;
        const id = (num1 | num2) & 0x7FFFFFFFFFFFFFFF;
        if (id != invalid_id) return @intCast(id);
    }
}

fn hashString64(text: []const u8) u64 {
    return hash.hash64Utf32Bytes(text);
}

fn md5HexLower(out: *[32]u8, bytes: []const u8) !void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &digest, .{});
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = chars[b >> 4];
        out[i * 2 + 1] = chars[b & 0x0f];
    }
}

test "uid encode/decode round trip" {
    const allocator = std.testing.allocator;
    const samples = [_]i64{ 0, 1, 34, 123456789, 9223372036854775807 };
    for (samples) |sample| {
        const text = try idToText(allocator, sample);
        defer allocator.free(text);
        try std.testing.expectEqual(sample, textToId(text));
    }
}

test "uid encode known vectors from Godot 4.7" {
    const allocator = std.testing.allocator;
    const text0 = try idToText(allocator, 0);
    defer allocator.free(text0);
    try std.testing.expectEqualStrings("uid://a", text0);

    const text1 = try idToText(allocator, 1);
    defer allocator.free(text1);
    try std.testing.expectEqualStrings("uid://b", text1);

    const text34 = try idToText(allocator, 34);
    defer allocator.free(text34);
    try std.testing.expectEqualStrings("uid://ba", text34);

    const text_big = try idToText(allocator, 123456789);
    defer allocator.free(text_big);
    try std.testing.expectEqualStrings("uid://cyncsb", text_big);

    const text_max = try idToText(allocator, 9223372036854775807);
    defer allocator.free(text_max);
    try std.testing.expectEqualStrings("uid://d4n4ub6itg400", text_max);
}

test "create_id_for_path matches Godot fixture" {
    const project_name = "TestProject";
    const resource_path = "res://test.tscn";
    const file_bytes =
        \\[gd_scene format=3]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    const id = try createIdForPath(std.testing.allocator, project_name, resource_path, file_bytes);
    try std.testing.expectEqual(@as(i64, 1350303725746704497), id);

    const text = try idToText(std.testing.allocator, id);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("uid://tidkmw585t0t", text);
}
