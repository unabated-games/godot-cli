//! Godot `Resource::generate_scene_unique_id` and seeding.
//! Ported from `core/io/resource.cpp`.

const std = @import("std");
const hash = @import("hash.zig");
const pcg = @import("pcg.zig");

const characters: u32 = 5;
const char_count: u32 = 'z' - 'a';
const base: u32 = char_count + ('9' - '0');

var unique_id_gen = pcg.Pcg32{};
var seeded: bool = false;

/// Match `Resource::seed_scene_unique_id`.
pub fn seedSceneUniqueId(seed: u32) void {
    unique_id_gen.seed(seed);
    seeded = true;
}

/// Seed from a Godot resource path using `String::hash()` (djb2, 32-bit).
pub fn seedSceneUniqueIdFromPath(path: []const u8) void {
    var code_units: [512]u21 = undefined;
    if (path.len > code_units.len) {
        const owned = std.heap.page_allocator.alloc(u21, path.len) catch @panic("oom");
        defer std.heap.page_allocator.free(owned);
        for (path, 0..) |c, i| owned[i] = c;
        seedSceneUniqueId(@truncate(hash.hashUtf32(owned)));
        return;
    }
    for (path, 0..) |c, i| code_units[i] = c;
    seedSceneUniqueId(@truncate(hash.hashUtf32(code_units[0..path.len])));
}

/// Reset generator state (for tests).
pub fn resetSceneUniqueIdGenerator() void {
    unique_id_gen = .{};
    seeded = false;
}

/// Match `Resource::generate_scene_unique_id` when seeded.
pub fn generateSceneUniqueId() [characters]u8 {
    if (!seeded) {
        @panic("generateSceneUniqueId requires seedSceneUniqueId; Godot falls back to time-based seeding");
    }

    var random_num = unique_id_gen.nextU32();
    var out: [characters]u8 = undefined;
    for (0..characters) |i| {
        const c = random_num % base;
        if (c < char_count) {
            out[i] = 'a' + @as(u8, @intCast(c));
        } else {
            out[i] = '0' + @as(u8, @intCast(c - char_count));
        }
        random_num /= base;
    }
    return out;
}

/// Build a sub-resource id like `StandardMaterial3D_ab12c`.
pub fn formatSubResourceId(allocator: std.mem.Allocator, class_name: []const u8) ![]u8 {
    const suffix = generateSceneUniqueId();
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ class_name, &suffix });
}

/// Build an external resource id like `1_ab12c`.
pub fn formatExtResourceId(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const suffix = generateSceneUniqueId();
    return std.fmt.allocPrint(allocator, "{d}_{s}", .{ index, &suffix });
}

test "scene unique ids with path hash seed are deterministic" {
    const path = "res://test.tscn";
    var code_units: [path.len]u21 = undefined;
    for (path, 0..) |c, i| code_units[i] = c;
    const path_hash = hash.hashUtf32(&code_units);

    resetSceneUniqueIdGenerator();
    seedSceneUniqueId(path_hash);

    const expected = [_][]const u8{ "mf4mk", "37kl0", "8uh7m", "6uqi0", "ppyta" };
    for (expected) |exp| {
        const got = generateSceneUniqueId();
        try std.testing.expectEqualStrings(exp, &got);
    }
}

test "format helpers" {
    resetSceneUniqueIdGenerator();
    seedSceneUniqueId(1290995245);

    const ext = try formatExtResourceId(std.testing.allocator, 1);
    defer std.testing.allocator.free(ext);
    try std.testing.expectEqualStrings("1_mf4mk", ext);

    const sub = try formatSubResourceId(std.testing.allocator, "CapsuleShape3D");
    defer std.testing.allocator.free(sub);
    try std.testing.expectEqualStrings("CapsuleShape3D_37kl0", sub);
}
