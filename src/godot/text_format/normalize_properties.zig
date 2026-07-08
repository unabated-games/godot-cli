//! Rewrite property values through Variant parse → format for Godot-compatible text.

const std = @import("std");
const document = @import("document.zig");
const variant = @import("../variant/root.zig");

pub const Error = error{
    OutOfMemory,
};

pub const Stats = struct {
    normalized: usize = 0,
    preserved: usize = 0,
};

pub fn normalizeDocument(allocator: std.mem.Allocator, doc: *document.Document) Error!Stats {
    var stats: Stats = .{};
    for (doc.sections.items) |*section| {
        for (section.properties.items, 0..) |prop, prop_index| {
            const outcome = try normalizePropertyLine(allocator, prop.raw);
            switch (outcome) {
                .rewritten => |line| {
                    allocator.free(section.properties.items[prop_index].raw);
                    section.properties.items[prop_index].raw = line;
                    stats.normalized += 1;
                },
                .preserved => stats.preserved += 1,
            }
        }
    }
    return stats;
}

const Outcome = union(enum) {
    rewritten: []const u8,
    preserved,
};

fn normalizePropertyLine(allocator: std.mem.Allocator, raw: []const u8) Error!Outcome {
    const split = variant.property_line.splitPropertyLine(raw) orelse return .preserved;

    var parsed = variant.parse.parsePropertyValue(allocator, split.value_text) catch return .preserved;
    defer parsed.deinit(allocator);

    const formatted = parsed.formatForWrite(allocator) catch return .preserved;
    defer allocator.free(formatted);

    if (std.mem.eql(u8, split.value_text, formatted)) return .preserved;

    const line = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ split.name, formatted });
    return .{ .rewritten = line };
}

test "normalize float and quaternion aliases" {
    const allocator = std.testing.allocator;
    const source =
        \\[node name="Root" type="Node2D"]
        \\offset = Vector2(1.0, 2.0)
        \\rotation = Quat(0, 0, 0, 1)
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const stats = try normalizeDocument(allocator, &doc);
    try std.testing.expectEqual(@as(usize, 2), stats.normalized);
    try std.testing.expectEqual(@as(usize, 0), stats.preserved);

    const props = doc.sections.items[0].properties.items;
    try std.testing.expectEqualStrings("offset = Vector2(1, 2)", props[0].raw);
    try std.testing.expectEqualStrings("rotation = Quaternion(0, 0, 0, 1)", props[1].raw);
}

test "preserve property line on parse failure" {
    const allocator = std.testing.allocator;
    const source =
        \\[node name="Root" type="Node"]
        \\broken = not a valid variant!!!
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const stats = try normalizeDocument(allocator, &doc);
    try std.testing.expectEqual(@as(usize, 0), stats.normalized);
    try std.testing.expectEqual(@as(usize, 1), stats.preserved);
    try std.testing.expectEqualStrings("broken = not a valid variant!!!", doc.sections.items[0].properties.items[0].raw);
}

test "preserve already canonical property text" {
    const allocator = std.testing.allocator;
    const source =
        \\[node name="Root" type="Node"]
        \\visible = true
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const stats = try normalizeDocument(allocator, &doc);
    try std.testing.expectEqual(@as(usize, 0), stats.normalized);
    try std.testing.expectEqual(@as(usize, 1), stats.preserved);
}
