//! Serialize Godot text resource documents back to `.tscn` / `.tres` text.

const std = @import("std");
const io_util = @import("../../io_util.zig");
const tag = @import("tag.zig");
const document = @import("document.zig");
const save_prepare = @import("save_prepare.zig");

pub fn writeDocument(allocator: std.mem.Allocator, doc: *const document.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (doc.sections.items, 0..) |section, index| {
        if (section.leading_blank_lines > 0) {
            var i: usize = 0;
            while (i < section.leading_blank_lines) : (i += 1) {
                try out.append(allocator, '\n');
            }
        } else if (index > 0 and !contiguousWithPrevious(doc, index)) {
            try out.append(allocator, '\n');
        }

        const header = try tag.formatLine(allocator, &section.header);
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        try out.append(allocator, '\n');

        for (section.properties.items) |prop| {
            try out.appendSlice(allocator, prop.raw);
            try out.append(allocator, '\n');
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Godot separates every section with a blank line except consecutive
/// `[connection]` lines, which it writes one after another.
fn contiguousWithPrevious(doc: *const document.Document, index: usize) bool {
    const current = doc.sections.items[index];
    const previous = doc.sections.items[index - 1];
    return std.mem.eql(u8, current.header.name, "connection") and
        std.mem.eql(u8, previous.header.name, "connection");
}

const error_details = @import("../error_details.zig");

pub fn writeFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    doc: *document.Document,
    prepare: ?save_prepare.SaveOptions,
) !void {
    if (prepare) |options| {
        try save_prepare.prepareDocument(allocator, doc, options);
    }
    const bytes = try writeDocument(allocator, doc);
    defer allocator.free(bytes);
    io_util.writeFile(path, bytes) catch |err| {
        error_details.record(.{ .field = "output", .value = path });
        return err;
    };
}

test "round trip preserves structure" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://foo.gd" id="1_ldc4g"]
        \\
        \\[node name="Root" type="Node"]
        \\script = ExtResource("1_ldc4g")
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const written = try writeDocument(allocator, &doc);
    defer allocator.free(written);

    var reparsed = try document.parseBytes(allocator, written);
    defer reparsed.deinit(allocator);

    try std.testing.expectEqual(doc.sections.items.len, reparsed.sections.items.len);
    try std.testing.expectEqualStrings("1_ldc4g", reparsed.sections.items[1].header.getString("id").?);
    try std.testing.expectEqualStrings("script = ExtResource(\"1_ldc4g\")", reparsed.sections.items[2].properties.items[0].raw);
}
