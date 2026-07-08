//! Deterministic node `unique_id` generation for save preparation.
//! Godot uses crypto-random `ResourceUID::create_id()` at runtime; we use seeded PCG
//! so CLI saves are reproducible for the same seed path.

const std = @import("std");
const hash = @import("hash.zig");
const pcg = @import("pcg.zig");

var node_id_gen = pcg.Pcg32{};
var seeded: bool = false;

pub fn resetNodeUniqueIdGenerator() void {
    node_id_gen = .{};
    seeded = false;
}

pub fn seedNodeUniqueIdGeneratorFromPath(path: []const u8) void {
    var code_units: [512]u21 = undefined;
    if (path.len > code_units.len) {
        const owned = std.heap.page_allocator.alloc(u21, path.len) catch @panic("oom");
        defer std.heap.page_allocator.free(owned);
        for (path, 0..) |c, i| owned[i] = c;
        seedNodeUniqueIdGenerator(@truncate(hash.hashUtf32(owned) ^ 0x6e0de1d5));
        return;
    }
    for (path, 0..) |c, i| code_units[i] = c;
    seedNodeUniqueIdGenerator(@truncate(hash.hashUtf32(code_units[0..path.len]) ^ 0x6e0de1d5));
}

fn seedNodeUniqueIdGenerator(seed: u32) void {
    node_id_gen.seed(seed);
    seeded = true;
}

/// Positive int32 suitable for `[node … unique_id=N]` (skips 0).
pub fn generateNodeUniqueId(used: *std.AutoHashMap(i32, void)) i32 {
    if (!seeded) @panic("generateNodeUniqueId requires seedNodeUniqueIdGeneratorFromPath");

    while (true) {
        const data = node_id_gen.nextU32();
        var id: i32 = @bitCast(data & 0x7FFFFFFF);
        if (id == 0) id = 1;
        if (!used.contains(id)) return id;
    }
}

test "node unique ids are deterministic" {
    resetNodeUniqueIdGenerator();
    seedNodeUniqueIdGeneratorFromPath("res://test.tscn");

    var used = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer used.deinit();

    const a = generateNodeUniqueId(&used);
    _ = try used.put(a, {});
    const b = generateNodeUniqueId(&used);

    resetNodeUniqueIdGenerator();
    seedNodeUniqueIdGeneratorFromPath("res://test.tscn");
    var used2 = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer used2.deinit();
    try std.testing.expectEqual(a, generateNodeUniqueId(&used2));
    _ = try used2.put(a, {});
    try std.testing.expectEqual(b, generateNodeUniqueId(&used2));
}
