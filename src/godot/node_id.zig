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
    seedNodeUniqueIdGenerator(@truncate(hash.hashUtf32Bytes(path) ^ 0x6e0de1d5));
}

fn seedNodeUniqueIdGenerator(seed: u32) void {
    node_id_gen.seed(seed);
    seeded = true;
}

pub const Error = error{
    /// The generator was used before `seedNodeUniqueIdGeneratorFromPath`.
    /// Refused rather than defaulted, so CLI output stays reproducible.
    GeneratorNotSeeded,
};

/// Positive int32 suitable for `[node … unique_id=N]` (skips 0).
pub fn generateNodeUniqueId(used: *std.AutoHashMap(i32, void)) Error!i32 {
    if (!seeded) return error.GeneratorNotSeeded;

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

    const a = try generateNodeUniqueId(&used);
    _ = try used.put(a, {});
    const b = try generateNodeUniqueId(&used);

    resetNodeUniqueIdGenerator();
    seedNodeUniqueIdGeneratorFromPath("res://test.tscn");
    var used2 = std.AutoHashMap(i32, void).init(std.testing.allocator);
    defer used2.deinit();
    try std.testing.expectEqual(a, try generateNodeUniqueId(&used2));
    _ = try used2.put(a, {});
    try std.testing.expectEqual(b, try generateNodeUniqueId(&used2));
}
