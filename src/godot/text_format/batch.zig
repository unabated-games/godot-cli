//! Batch and multi-file text format operations.

const std = @import("std");
const document = @import("document.zig");
const tag = @import("tag.zig");

pub fn retargetExtResourcePaths(doc: *document.Document, allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8) !usize {
    var count: usize = 0;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const path = section.header.getString("path") orelse continue;
        if (!std.mem.eql(u8, path, from_path)) continue;
        try section.header.setStringField(allocator, "path", to_path);
        count += 1;
    }
    return count;
}

test "retarget ext_resource path" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://old.gd" id="1_abc"]
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const n = try retargetExtResourcePaths(&doc, allocator, "res://old.gd", "res://new.gd");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("res://new.gd", doc.sections.items[1].header.getString("path").?);
}
