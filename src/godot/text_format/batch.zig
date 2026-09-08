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

/// Rename an `ext_resource` id and every `ExtResource("id")` that points at
/// it. godot-cli seeds an id from the file's name (`Script_player`), so after
/// a move the id can name a file that no longer exists — correct, since the
/// id is arbitrary, but it reads oddly in a diff.
///
/// Returns the number of references rewritten, or null when the new id is
/// already taken, since two sections sharing an id would break the file.
pub fn renameExtResourceId(doc: *document.Document, allocator: std.mem.Allocator, old_id: []const u8, new_id: []const u8) !?usize {
    if (std.mem.eql(u8, old_id, new_id)) return 0;
    var target: ?*document.Section = null;
    for (doc.sections.items) |*section| {
        const id = section.header.getString("id") orelse continue;
        if (std.mem.eql(u8, id, new_id)) return null;
        if (std.mem.eql(u8, section.header.name, "ext_resource") and std.mem.eql(u8, id, old_id)) target = section;
    }
    const section = target orelse return null;
    // old_id points into the header field that setStringField is about to
    // replace, so the reference text has to be built before that happens.
    const old_ref = try std.fmt.allocPrint(allocator, "ExtResource(\"{s}\")", .{old_id});
    try section.header.setStringField(allocator, "id", new_id);

    defer allocator.free(old_ref);
    const new_ref = try std.fmt.allocPrint(allocator, "ExtResource(\"{s}\")", .{new_id});
    defer allocator.free(new_ref);

    var rewritten: usize = 0;
    for (doc.sections.items) |*other| {
        for (other.properties.items) |*line| {
            if (std.mem.indexOf(u8, line.raw, old_ref) == null) continue;
            const size = std.mem.replacementSize(u8, line.raw, old_ref, new_ref);
            const buffer = try allocator.alloc(u8, size);
            _ = std.mem.replace(u8, line.raw, old_ref, new_ref, buffer);
            allocator.free(line.raw);
            line.raw = buffer;
            rewritten += 1;
        }
    }
    return rewritten;
}

test "renaming an ext_resource id rewrites the references too" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://hero.gd" id="Script_player"]
        \\[node name="Root" type="Node2D"]
        \\script = ExtResource("Script_player")
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const n = (try renameExtResourceId(&doc, allocator, "Script_player", "Script_hero")).?;
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Script_hero", doc.sections.items[1].header.getString("id").?);
    try std.testing.expectEqualStrings("script = ExtResource(\"Script_hero\")", doc.sections.items[2].properties.items[0].raw);

    // A name already in use is refused rather than duplicated.
    try std.testing.expect((try renameExtResourceId(&doc, allocator, "Script_hero", "Script_hero")) != null);
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

test "a renamed id survives a write, references and all" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://hero.gd" id="Script_player"]
        \\
        \\[node name="Root" type="Node2D"]
        \\script = ExtResource("Script_player")
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);
    _ = try renameExtResourceId(&doc, allocator, "Script_player", "Script_hero");

    // The writer is what matters: mutating `raw` proves nothing if the writer
    // renders the property from somewhere else.
    const written = try @import("roundtrip.zig").writeDocumentPreserving(allocator, &doc);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "id=\"Script_hero\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ExtResource(\"Script_hero\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Script_player") == null);
}
