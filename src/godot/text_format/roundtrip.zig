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
    const difference = firstGodotSaveDifference(allocator, original, godot_saved) catch return false;
    if (difference) |text| {
        allocator.free(text);
        return false;
    }
    return true;
}

/// The first way `original` differs from a Godot save of it, or null when it
/// matches. Compared: the node tree (order, headers, `unique_id`), each node's
/// properties with ext_resource ids read as the paths they name, the
/// ext_resource paths, and the scene's and each ext_resource's `uid` wherever
/// both sides carry one. Not compared: ext_resource ids, which Godot renumbers;
/// `load_steps`; and sub_resources, whose default fields Godot drops. A
/// reference saved from a script can omit uids, so a missing one is not a
/// difference; trial 35's check matched a scene whose mesh uid was wrong.
pub fn firstGodotSaveDifference(allocator: std.mem.Allocator, original: *const document.Document, godot_saved: *const document.Document) !?[]const u8 {
    const orig_nodes = try collectNodeSections(allocator, original);
    defer allocator.free(orig_nodes);
    const saved_nodes = try collectNodeSections(allocator, godot_saved);
    defer allocator.free(saved_nodes);
    if (orig_nodes.len != saved_nodes.len) {
        return try std.fmt.allocPrint(allocator, "{d} node(s) here, {d} in the Godot save", .{ orig_nodes.len, saved_nodes.len });
    }

    if (headerUid(original)) |a| if (headerUid(godot_saved)) |b| if (!std.mem.eql(u8, a, b)) {
        return try std.fmt.allocPrint(allocator, "the scene's uid is {s} here and {s} in the Godot save", .{ a, b });
    };

    const orig_ext = collectExtResourcePaths(allocator, original) catch return try allocator.dupe(u8, "an ext_resource here has no path");
    defer allocator.free(orig_ext);
    const saved_ext = collectExtResourcePaths(allocator, godot_saved) catch return try allocator.dupe(u8, "an ext_resource in the Godot save has no path");
    defer allocator.free(saved_ext);
    if (orig_ext.len != saved_ext.len) {
        return try std.fmt.allocPrint(allocator, "{d} ext_resource(s) here, {d} in the Godot save", .{ orig_ext.len, saved_ext.len });
    }
    for (orig_ext, saved_ext) |a, b| {
        if (!std.mem.eql(u8, a, b)) return try std.fmt.allocPrint(allocator, "ext_resource {s} here where the Godot save has {s}", .{ a, b });
        if (extUid(original, a)) |uid_a| if (extUid(godot_saved, b)) |uid_b| if (!std.mem.eql(u8, uid_a, uid_b)) {
            return try std.fmt.allocPrint(allocator, "ext_resource {s} has uid {s} here and {s} in the Godot save", .{ a, uid_a, uid_b });
        };
    }

    var orig_ids = try buildExtIdToPath(allocator, original);
    defer orig_ids.deinit();
    var saved_ids = try buildExtIdToPath(allocator, godot_saved);
    defer saved_ids.deinit();
    for (orig_nodes, saved_nodes) |na, nb| {
        const name = na.header.getString("name") orelse "?";
        for ([_][]const u8{ "name", "type", "parent", "unique_id" }) |field| {
            if (!headerFieldEqual(&na.header, &nb.header, field)) {
                return try std.fmt.allocPrint(allocator, "node {s}: its {s} differs from the Godot save", .{ name, field });
            }
        }
        // An instance names its scene by ext_resource id, which a save to a
        // new path renumbers; compare the scene it names. Compared literally,
        // every instanced node was a mismatch against a `project resave` copy.
        const instance_a = na.header.getString("instance");
        const instance_b = nb.header.getString("instance");
        if ((instance_a == null) != (instance_b == null)) {
            return try std.fmt.allocPrint(allocator, "node {s}: it is an instance on only one side", .{name});
        }
        if (instance_a) |a| {
            const scene_a = try normalizeExtResourceRef(allocator, a, &orig_ids);
            defer allocator.free(scene_a);
            const scene_b = try normalizeExtResourceRef(allocator, instance_b.?, &saved_ids);
            defer allocator.free(scene_b);
            if (!std.mem.eql(u8, scene_a, scene_b)) {
                return try std.fmt.allocPrint(allocator, "node {s}: it instances {s} here and {s} in the Godot save", .{ name, scene_a, scene_b });
            }
        }
        if (!propertiesEquivalentIgnoringExtIds(allocator, na, nb, original, godot_saved)) {
            return try std.fmt.allocPrint(allocator, "node {s}: its properties differ from the Godot save (names, order, or values)", .{name});
        }
    }
    return null;
}

fn headerUid(doc: *const document.Document) ?[]const u8 {
    if (doc.sections.items.len == 0) return null;
    return doc.sections.items[0].header.getString("uid");
}

fn extUid(doc: *const document.Document, path: []const u8) ?[]const u8 {
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const section_path = section.header.getString("path") orelse continue;
        if (std.mem.eql(u8, section_path, path)) return section.header.getString("uid");
    }
    return null;
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
        headerFieldEqual(&a, &b, "instance") and
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
        .raw => |s| switch (b) {
            .raw => |t| std.mem.eql(u8, s, t),
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

test "a Godot save with a different uid is a difference, a missing one is not" {
    // Trial 35's compare matched a scene whose mesh uid had been swapped.
    const allocator = std.testing.allocator;
    const scene =
        \\[gd_scene format=3 uid="uid://c8quarrymain1"]
        \\
        \\[ext_resource type="BoxMesh" uid="uid://bc628hhe4x5yp" path="res://crate.res" id="1_crate"]
        \\
        \\[node name="Main" type="Node3D"]
        \\
    ;
    var original = try document.parseBytes(allocator, scene);
    defer original.deinit(allocator);

    var wrong = try document.parseBytes(allocator, scene);
    defer wrong.deinit(allocator);
    try wrong.sections.items[1].header.setStringField(allocator, "uid", "uid://byggqned6p7ih");
    const difference = (try firstGodotSaveDifference(allocator, &original, &wrong)).?;
    defer allocator.free(difference);
    try std.testing.expect(std.mem.indexOf(u8, difference, "uid://byggqned6p7ih") != null);

    // A script-side save can leave uids out entirely: still a match.
    var bare = try document.parseBytes(allocator, scene);
    defer bare.deinit(allocator);
    bare.sections.items[1].header.removeField(allocator, "uid");
    bare.sections.items[0].header.removeField(allocator, "uid");
    try std.testing.expect(documentsMatchGodotSave(allocator, &original, &bare));
}

test "an instance is compared by the scene it names, not its ext_resource id" {
    // A save to a new path renumbers ext ids; `project resave` copies are
    // exactly that, and every instanced node read as a mismatch.
    const allocator = std.testing.allocator;
    var here = try document.parseBytes(allocator,
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://hud.tscn" id="1_aaaaa"]
        \\
        \\[node name="Main" type="Node"]
        \\
        \\[node name="HUD" parent="." instance=ExtResource("1_aaaaa")]
        \\
    );
    defer here.deinit(allocator);
    var saved = try document.parseBytes(allocator,
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://hud.tscn" id="1_bbbbb"]
        \\
        \\[node name="Main" type="Node"]
        \\
        \\[node name="HUD" parent="." instance=ExtResource("1_bbbbb")]
        \\
    );
    defer saved.deinit(allocator);
    try std.testing.expect(documentsMatchGodotSave(allocator, &here, &saved));
}
