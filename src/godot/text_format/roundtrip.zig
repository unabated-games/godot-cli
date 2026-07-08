//! Round-trip helpers: parse → write without mutation and compare structure.

const std = @import("std");
const document = @import("document.zig");
const writer = @import("writer.zig");
const tag = @import("tag.zig");

pub fn writeDocumentPreserving(allocator: std.mem.Allocator, doc: *const document.Document) ![]u8 {
    return writer.writeDocument(allocator, doc);
}

/// Compare two documents section-by-section (headers + property raw lines).
pub fn documentsEqual(a: *const document.Document, b: *const document.Document) bool {
    if (a.sections.items.len != b.sections.items.len) return false;
    for (a.sections.items, b.sections.items) |sa, sb| {
        if (sa.leading_blank_lines != sb.leading_blank_lines) return false;
        if (!std.mem.eql(u8, sa.header.name, sb.header.name)) return false;
        if (sa.properties.items.len != sb.properties.items.len) return false;
        for (sa.properties.items, sb.properties.items) |pa, pb| {
            if (!std.mem.eql(u8, pa.raw, pb.raw)) return false;
        }
        if (!headersFieldsEqual(&sa.header, &sb.header)) return false;
    }
    return true;
}

/// Godot save may rewrite ext_resource ids, drop default sub_resource fields, and omit load_steps.
/// This compares node tree shape, ext paths, and normalized property values.
pub fn documentsMatchGodotSave(allocator: std.mem.Allocator, original: *const document.Document, godot_saved: *const document.Document) bool {
    const orig_nodes = collectNodeSections(allocator, original) catch return false;
    defer allocator.free(orig_nodes);
    const saved_nodes = collectNodeSections(allocator, godot_saved) catch return false;
    defer allocator.free(saved_nodes);

    if (orig_nodes.len != saved_nodes.len) return false;

    const orig_ext = collectExtResourcePaths(allocator, original) catch return false;
    defer allocator.free(orig_ext);
    const saved_ext = collectExtResourcePaths(allocator, godot_saved) catch return false;
    defer allocator.free(saved_ext);

    if (orig_ext.len != saved_ext.len) return false;
    for (orig_ext, saved_ext) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }

    for (orig_nodes, saved_nodes) |na, nb| {
        if (!nodeHeadersEquivalent(na.header, nb.header)) return false;
        if (!propertiesEquivalentIgnoringExtIds(allocator, na, nb, original, godot_saved)) return false;
    }
    return true;
}

const NodeView = struct {
    header: tag.Tag,
    properties: []const document.PropertyLine,
};

fn collectNodeSections(allocator: std.mem.Allocator, doc: *const document.Document) ![]NodeView {
    var out: std.ArrayList(NodeView) = .empty;
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "node")) continue;
        try out.append(allocator, .{
            .header = section.header,
            .properties = section.properties.items,
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn collectExtResourcePaths(allocator: std.mem.Allocator, doc: *const document.Document) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const path = section.header.getString("path") orelse return error.InvalidData;
        try out.append(allocator, path);
    }
    return try out.toOwnedSlice(allocator);
}

const InvalidData = error{InvalidData};

fn nodeHeadersEquivalent(a: tag.Tag, b: tag.Tag) bool {
    return headerFieldEqual(&a, &b, "name") and
        headerFieldEqual(&a, &b, "type") and
        headerFieldEqual(&a, &b, "parent") and
        headerFieldEqual(&a, &b, "unique_id");
}

fn headerFieldEqual(a: *const tag.Tag, b: *const tag.Tag, key: []const u8) bool {
    if (a.getInteger(key)) |ai| {
        return b.getInteger(key) == ai;
    }
    const as = a.getString(key);
    const bs = b.getString(key);
    if (as == null and bs == null) return true;
    if (as == null or bs == null) return false;
    return std.mem.eql(u8, as.?, bs.?);
}

fn propertiesEquivalentIgnoringExtIds(
    allocator: std.mem.Allocator,
    na: NodeView,
    nb: NodeView,
    original: *const document.Document,
    godot_saved: *const document.Document,
) bool {
    if (na.properties.len != nb.properties.len) return false;

    var orig_map = buildExtIdToPath(allocator, original) catch return false;
    defer orig_map.deinit();
    var saved_map = buildExtIdToPath(allocator, godot_saved) catch return false;
    defer saved_map.deinit();

    for (na.properties, nb.properties) |pa, pb| {
        const key_a = propertyKey(pa.raw) orelse return false;
        const key_b = propertyKey(pb.raw) orelse return false;
        if (!std.mem.eql(u8, key_a, key_b)) return false;

        const norm_a = normalizeExtResourceRef(allocator, pa.raw, &orig_map) catch return false;
        defer allocator.free(norm_a);
        const norm_b = normalizeExtResourceRef(allocator, pb.raw, &saved_map) catch return false;
        defer allocator.free(norm_b);
        if (!std.mem.eql(u8, norm_a, norm_b)) return false;
    }
    return true;
}

fn propertyKey(raw: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return std.mem.trim(u8, raw[0..eq], &std.ascii.whitespace);
}

fn buildExtIdToPath(allocator: std.mem.Allocator, doc: *const document.Document) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const id = section.header.getString("id") orelse continue;
        const path = section.header.getString("path") orelse continue;
        try map.put(id, path);
    }
    return map;
}

fn normalizeExtResourceRef(allocator: std.mem.Allocator, raw: []const u8, id_to_path: *const std.StringHashMap([]const u8)) ![]u8 {
    const prefix = "ExtResource(\"";
    if (std.mem.indexOf(u8, raw, prefix)) |start| {
        const id_start = start + prefix.len;
        const id_end = std.mem.indexOfPos(u8, raw, id_start, "\"") orelse return allocator.dupe(u8, raw);
        const id = raw[id_start..id_end];
        if (id_to_path.get(id)) |path| {
            return std.fmt.allocPrint(allocator, "ExtResource(\"{s}\")", .{path});
        }
    }
    return allocator.dupe(u8, raw);
}

fn headersFieldsEqual(a: *const tag.Tag, b: *const tag.Tag) bool {
    if (a.fields.count() != b.fields.count()) return false;
    var it = a.fields.iterator();
    while (it.next()) |entry| {
        const other = b.fields.get(entry.key_ptr.*) orelse return false;
        if (!valuesEqual(entry.value_ptr.*, other)) return false;
    }
    return true;
}

fn valuesEqual(a: @import("tag.zig").Value, b: @import("tag.zig").Value) bool {
    return switch (a) {
        .string => |s| switch (b) {
            .string => |t| std.mem.eql(u8, s, t),
            else => false,
        },
        .integer => |n| switch (b) {
            .integer => |m| n == m,
            else => false,
        },
        .float => |f| switch (b) {
            .float => |g| f == g,
            else => false,
        },
        .bool => |v| switch (b) {
            .bool => |w| v == w,
            else => false,
        },
    };
}

test "parse write parse preserves sample scene structure" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=3 format=3 uid="uid://tidkmw585t0t"]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_mf4mk"]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_37kl0"]
        \\radius = 0.5
        \\height = 2.0
        \\
        \\[node name="Root" type="Node3D" unique_id=1290995245]
        \\script = ExtResource("1_mf4mk")
        \\visible = true
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="Root" unique_id=987654321]
        \\shape = SubResource("CapsuleShape3D_37kl0")
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const written = try writeDocumentPreserving(allocator, &doc);
    defer allocator.free(written);

    var reparsed = try document.parseBytes(allocator, written);
    defer reparsed.deinit(allocator);

    try std.testing.expect(documentsEqual(&doc, &reparsed));
}

test "sample scene matches Godot headless save structure" {
    const allocator = std.testing.allocator;
    const sample =
        \\[gd_scene load_steps=3 format=3 uid="uid://tidkmw585t0t"]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_mf4mk"]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_37kl0"]
        \\radius = 0.5
        \\height = 2.0
        \\
        \\[node name="Root" type="Node3D" unique_id=1290995245]
        \\script = ExtResource("1_mf4mk")
        \\visible = true
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="Root" unique_id=987654321]
        \\shape = SubResource("CapsuleShape3D_37kl0")
        \\
    ;
    const godot_saved =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_a7oy8"]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_37kl0"]
        \\
        \\[node name="Root" type="Node3D" unique_id=1290995245]
        \\script = ExtResource("1_a7oy8")
        \\visible = true
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="Root" unique_id=987654321]
        \\shape = SubResource("CapsuleShape3D_37kl0")
        \\
    ;

    var original = try document.parseBytes(allocator, sample);
    defer original.deinit(allocator);
    var saved = try document.parseBytes(allocator, godot_saved);
    defer saved.deinit(allocator);

    try std.testing.expect(documentsMatchGodotSave(allocator, &original, &saved));
}

test "byte-identical Godot save with id session and format stripping" {
    const allocator = std.testing.allocator;
    const save_prepare = @import("save_prepare.zig");
    const id_session_mod = @import("../id_session.zig");

    const sample =
        \\[gd_scene load_steps=3 format=3 uid="uid://tidkmw585t0t"]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_mf4mk"]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_37kl0"]
        \\radius = 0.5
        \\height = 2.0
        \\
        \\[node name="Root" type="Node3D" unique_id=1290995245]
        \\script = ExtResource("1_mf4mk")
        \\visible = true
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="Root" unique_id=987654321]
        \\shape = SubResource("CapsuleShape3D_37kl0")
        \\
    ;
    const godot_saved =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_a7oy8"]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_37kl0"]
        \\
        \\[node name="Root" type="Node3D" unique_id=1290995245]
        \\script = ExtResource("1_a7oy8")
        \\visible = true
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="Root" unique_id=987654321]
        \\shape = SubResource("CapsuleShape3D_37kl0")
        \\
    ;

    var session = id_session_mod.Session.init(allocator);
    defer session.deinit(allocator);
    try session.setExtId(allocator, "res://sample.tscn", "res://id_reference.gd", "1_a7oy8");

    var doc = try document.parseBytes(allocator, sample);
    defer doc.deinit(allocator);

    try save_prepare.prepareDocument(allocator, &doc, .{
        .seed_path = "res://sample.tscn",
        .id_session = &session,
        .godot_save_format = true,
    });

    const written = try writer.writeDocument(allocator, &doc);
    defer allocator.free(written);

    try std.testing.expectEqualStrings(godot_saved, written);
}
