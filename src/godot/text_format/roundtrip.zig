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
        return try allocator.print("{d} node(s) here, {d} in the Godot save", .{ orig_nodes.len, saved_nodes.len });
    }

    if (headerUid(original)) |a| if (headerUid(godot_saved)) |b| if (!std.mem.eql(u8, a, b)) {
        return try allocator.print("the scene's uid is {s} here and {s} in the Godot save", .{ a, b });
    };

    const orig_ext = collectExtResourcePaths(allocator, original) catch return try allocator.dupe(u8, "an ext_resource here has no path");
    defer allocator.free(orig_ext);
    const saved_ext = collectExtResourcePaths(allocator, godot_saved) catch return try allocator.dupe(u8, "an ext_resource in the Godot save has no path");
    defer allocator.free(saved_ext);
    if (orig_ext.len != saved_ext.len) {
        return try allocator.print("{d} ext_resource(s) here, {d} in the Godot save", .{ orig_ext.len, saved_ext.len });
    }
    for (orig_ext, saved_ext) |a, b| {
        if (!std.mem.eql(u8, a, b)) return try allocator.print("ext_resource {s} here where the Godot save has {s}", .{ a, b });
        if (extUid(original, a)) |uid_a| if (extUid(godot_saved, b)) |uid_b| if (!std.mem.eql(u8, uid_a, uid_b)) {
            return try allocator.print("ext_resource {s} has uid {s} here and {s} in the Godot save", .{ a, uid_a, uid_b });
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
                return try allocator.print("node {s}: its {s} differs from the Godot save", .{ name, field });
            }
        }
        // An instance names its scene by ext_resource id, which a save to a
        // new path renumbers; compare the scene it names. Compared literally,
        // every instanced node was a mismatch against a `project resave` copy.
        const instance_a = na.header.getString("instance");
        const instance_b = nb.header.getString("instance");
        if ((instance_a == null) != (instance_b == null)) {
            return try allocator.print("node {s}: it is an instance on only one side", .{name});
        }
        if (instance_a) |a| {
            const scene_a = try normalizeExtResourceRef(allocator, a, &orig_ids);
            defer allocator.free(scene_a);
            const scene_b = try normalizeExtResourceRef(allocator, instance_b.?, &saved_ids);
            defer allocator.free(scene_b);
            if (!std.mem.eql(u8, scene_a, scene_b)) {
                return try allocator.print("node {s}: it instances {s} here and {s} in the Godot save", .{ name, scene_a, scene_b });
            }
        }
        if (!propertiesEquivalentIgnoringExtIds(allocator, na, nb, original, godot_saved)) {
            const detail = try describePropertyDifference(allocator, na, nb, original, godot_saved);
            defer allocator.free(detail);
            return try allocator.print("node {s}: {s}", .{ name, detail });
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

/// The same properties with the same values, ext_resource ids read as the
/// paths they name. Order is not compared: the editor writes its class
/// order, and so does godot-cli's save, but a file written elsewhere may
/// not, and the editor's next save reorders it without changing what it
/// says; `skippedGodotSaveDifferences` lists it instead.
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

    for (na.properties) |pa| {
        const key_a = propertyKey(pa.raw) orelse return false;
        const pb = findProperty(nb, key_a) orelse return false;
        const norm_a = normalizeExtResourceRef(allocator, pa.raw, &orig_map) catch return false;
        defer allocator.free(norm_a);
        const norm_b = normalizeExtResourceRef(allocator, pb.raw, &saved_map) catch return false;
        defer allocator.free(norm_b);
        if (!std.mem.eql(u8, norm_a, norm_b)) return false;
    }
    return true;
}

fn findProperty(node: NodeView, key: []const u8) ?document.PropertyLine {
    for (node.properties) |p| {
        if (propertyKey(p.raw)) |k| if (std.mem.eql(u8, k, key)) return p;
    }
    return null;
}

/// Which way two nodes' properties differ: names only one side has, the
/// same names in another order, or the first value that differs. "Its
/// properties differ" left the caller to diff the files to find out.
fn describePropertyDifference(
    allocator: std.mem.Allocator,
    na: NodeView,
    nb: NodeView,
    original: *const document.Document,
    godot_saved: *const document.Document,
) ![]u8 {
    var only_here: std.ArrayList([]const u8) = .empty;
    defer only_here.deinit(allocator);
    var only_saved: std.ArrayList([]const u8) = .empty;
    defer only_saved.deinit(allocator);
    for (na.properties) |pa| {
        const key = propertyKey(pa.raw) orelse continue;
        if (!hasProperty(nb, key)) try only_here.append(allocator, key);
    }
    for (nb.properties) |pb| {
        const key = propertyKey(pb.raw) orelse continue;
        if (!hasProperty(na, key)) try only_saved.append(allocator, key);
    }
    if (only_here.items.len > 0 or only_saved.items.len > 0) {
        const here = try std.mem.join(allocator, ", ", only_here.items);
        defer allocator.free(here);
        const saved = try std.mem.join(allocator, ", ", only_saved.items);
        defer allocator.free(saved);
        return allocator.print("{s}{s}{s}{s}{s}", .{
            if (only_here.items.len > 0) "here only: " else "",
            here,
            if (only_here.items.len > 0 and only_saved.items.len > 0) "; " else "",
            if (only_saved.items.len > 0) "the Godot save only: " else "",
            saved,
        });
    }
    var orig_map = try buildExtIdToPath(allocator, original);
    defer orig_map.deinit();
    var saved_map = try buildExtIdToPath(allocator, godot_saved);
    defer saved_map.deinit();
    for (na.properties) |pa| {
        const key_a = propertyKey(pa.raw) orelse continue;
        const pb = findProperty(nb, key_a) orelse continue;
        const norm_a = try normalizeExtResourceRef(allocator, pa.raw, &orig_map);
        defer allocator.free(norm_a);
        const norm_b = try normalizeExtResourceRef(allocator, pb.raw, &saved_map);
        defer allocator.free(norm_b);
        if (!std.mem.eql(u8, norm_a, norm_b)) {
            return allocator.print("{s} is {s} here and {s} in the Godot save", .{ key_a, valueText(pa.raw), valueText(pb.raw) });
        }
    }
    return allocator.dupe(u8, "its properties differ from the Godot save");
}

fn hasProperty(node: NodeView, key: []const u8) bool {
    for (node.properties) |p| {
        if (propertyKey(p.raw)) |k| if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn valueText(raw: []const u8) []const u8 {
    const eq = std.mem.indexOf(u8, raw, " = ") orelse return raw;
    const value = raw[eq + 3 ..];
    return if (value.len > 80) value[0..80] else value;
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
            return allocator.print("ExtResource(\"{s}\")", .{path});
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
        \\visible = true
        \\script = ExtResource("1_a7oy8")
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

/// What `firstGodotSaveDifference` leaves out, listed: each difference
/// between the two files in the parts it does not compare (ext_resource ids,
/// a uid only one side carries, load_steps, sub_resources, connections and
/// other sections that are not nodes). A match with this empty means the
/// files agree everywhere a reader would look; trial 37 diffed the files by
/// hand to learn that.
pub fn skippedGodotSaveDifferences(allocator: std.mem.Allocator, original: *const document.Document, godot_saved: *const document.Document) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    if (original.sections.items.len > 0 and godot_saved.sections.items.len > 0) {
        const head_a = &original.sections.items[0].header;
        const head_b = &godot_saved.sections.items[0].header;
        if (head_a.getInteger("load_steps") != head_b.getInteger("load_steps")) {
            try out.append(allocator, try allocator.print("load_steps: {s} here, {s} in the Godot save", .{ try intText(allocator, head_a.getInteger("load_steps")), try intText(allocator, head_b.getInteger("load_steps")) }));
        }
        const uid_a = head_a.getString("uid");
        const uid_b = head_b.getString("uid");
        if ((uid_a == null) != (uid_b == null)) {
            try out.append(allocator, try allocator.print("the scene's uid: {s} here, {s} in the Godot save", .{ uid_a orelse "none", uid_b orelse "none" }));
        }
    }

    for (original.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const path = section.header.getString("path") orelse continue;
        const other = findSectionBy(godot_saved, "ext_resource", "path", path) orelse continue;
        const id_a = section.header.getString("id") orelse "";
        const id_b = other.header.getString("id") orelse "";
        if (!std.mem.eql(u8, id_a, id_b)) {
            try out.append(allocator, try allocator.print("ext_resource {s}: id {s} here, {s} in the Godot save", .{ path, id_a, id_b }));
        }
        const uid_a = section.header.getString("uid");
        const uid_b = other.header.getString("uid");
        if ((uid_a == null) != (uid_b == null)) {
            try out.append(allocator, try allocator.print("ext_resource {s}: uid {s} here, {s} in the Godot save", .{ path, uid_a orelse "none", uid_b orelse "none" }));
        }
    }

    // sub_resources by id, which a save keeps; anything else by its text.
    for (original.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
        const id = section.header.getString("id") orelse continue;
        const other = findSectionBy(godot_saved, "sub_resource", "id", id) orelse {
            try out.append(allocator, try allocator.print("sub_resource {s}: here only", .{id}));
            continue;
        };
        const text_a = try writer.writeSection(allocator, section);
        const text_b = try writer.writeSection(allocator, other);
        if (!std.mem.eql(u8, text_a, text_b)) {
            const fields_a = section.properties.items.len;
            const fields_b = other.properties.items.len;
            try out.append(allocator, if (fields_a != fields_b)
                try allocator.print("sub_resource {s}: {d} field(s) here, {d} in the Godot save, which drops fields left at their default", .{ id, fields_a, fields_b })
            else
                try allocator.print("sub_resource {s}: its fields differ from the Godot save", .{id}));
        }
    }
    for (godot_saved.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
        const id = section.header.getString("id") orelse continue;
        if (findSectionBy(original, "sub_resource", "id", id) == null) {
            try out.append(allocator, try allocator.print("sub_resource {s}: in the Godot save only", .{id}));
        }
    }

    // The same sub_resources in another order (trial 46 found this only
    // with a plain diff): Godot writes each after the ones it refers to,
    // in the order its save reaches them.
    {
        var here: std.ArrayList([]const u8) = .empty;
        defer here.deinit(allocator);
        var there: std.ArrayList([]const u8) = .empty;
        defer there.deinit(allocator);
        for (original.sections.items) |*section| if (std.mem.eql(u8, section.header.name, "sub_resource")) {
            const id = section.header.getString("id") orelse continue;
            if (findSectionBy(godot_saved, "sub_resource", "id", id) != null) try here.append(allocator, id);
        };
        for (godot_saved.sections.items) |*section| if (std.mem.eql(u8, section.header.name, "sub_resource")) {
            const id = section.header.getString("id") orelse continue;
            if (findSectionBy(original, "sub_resource", "id", id) != null) try there.append(allocator, id);
        };
        for (here.items, there.items) |a, b| {
            if (std.mem.eql(u8, a, b)) continue;
            try out.append(allocator, try allocator.print("sub_resources in another order: {s} comes where the Godot save has {s}; a godot-cli save writes Godot's order", .{ a, b }));
            break;
        }
    }

    // Nodes whose properties match but sit in another order: the editor
    // writes its class order, and its next save reorders them.
    const nodes_a = try collectNodeSections(allocator, original);
    defer allocator.free(nodes_a);
    const nodes_b = try collectNodeSections(allocator, godot_saved);
    defer allocator.free(nodes_b);
    if (nodes_a.len == nodes_b.len) for (nodes_a, nodes_b) |na, nb| {
        if (na.properties.len != nb.properties.len) continue;
        for (na.properties, nb.properties) |pa, pb| {
            const key_a = propertyKey(pa.raw) orelse continue;
            const key_b = propertyKey(pb.raw) orelse continue;
            if (std.mem.eql(u8, key_a, key_b)) continue;
            try out.append(allocator, try allocator.print("node {s}: the same properties in another order, {s} where the Godot save has {s}; the editor writes its class order, and its next save reorders them", .{ na.header.getString("name") orelse "?", key_a, key_b }));
            break;
        }
    };

    try appendOneSided(allocator, &out, original, godot_saved, "here only");
    try appendOneSided(allocator, &out, godot_saved, original, "in the Godot save only");
    return out.items;
}

fn intText(allocator: std.mem.Allocator, value: ?i64) ![]const u8 {
    return if (value) |v| try allocator.print("{d}", .{v}) else "none";
}

fn findSectionBy(doc: *const document.Document, name: []const u8, key: []const u8, value: []const u8) ?*const document.Section {
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, name)) continue;
        const got = section.header.getString(key) orelse continue;
        if (std.mem.eql(u8, got, value)) return section;
    }
    return null;
}

/// Sections other than the header, nodes, ext_resources and sub_resources
/// (connections, editable paths, a .tres's [resource]) that `a` has and `b`
/// does not, compared by their written text.
fn appendOneSided(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), a: *const document.Document, b: *const document.Document, side: []const u8) !void {
    const compared = [_][]const u8{ "node", "ext_resource", "sub_resource" };
    for (a.sections.items, 0..) |*section, index| {
        if (index == 0) continue;
        const skip = for (compared) |name| {
            if (std.mem.eql(u8, section.header.name, name)) break true;
        } else false;
        if (skip) continue;
        const text = try writer.writeSection(allocator, section);
        const found = for (b.sections.items, 0..) |*other, other_index| {
            if (other_index == 0 or !std.mem.eql(u8, other.header.name, section.header.name)) continue;
            if (std.mem.eql(u8, text, try writer.writeSection(allocator, other))) break true;
        } else false;
        if (!found) {
            const first_line = std.mem.trimEnd(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \r");
            try out.append(allocator, try allocator.print("{s} {s}", .{ first_line, side }));
        }
    }
}

test "what a Godot-save comparison leaves out is listed" {
    // Trial 37 matched, then diffed the files by hand to learn what the
    // match had not looked at.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var here = try document.parseBytes(allocator,
        \\[gd_scene load_steps=3 format=3 uid="uid://c8quarrymain1"]
        \\
        \\[ext_resource type="Texture2D" uid="uid://bc628hhe4x5yp" path="res://icon.svg" id="Texture2D_icon"]
        \\
        \\[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_a"]
        \\bg_color = Color(1, 0, 0, 1)
        \\corner_radius_top_left = 0
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[connection signal="ready" from="." to="." method="_on_ready"]
        \\
    );
    var saved = try document.parseBytes(allocator,
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Texture2D" path="res://icon.svg" id="1_kqc8k"]
        \\
        \\[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_a"]
        \\bg_color = Color(1, 0, 0, 1)
        \\
        \\[node name="Main" type="Node2D"]
        \\
    );
    try std.testing.expect(documentsMatchGodotSave(allocator, &here, &saved));
    const skipped = try skippedGodotSaveDifferences(allocator, &here, &saved);
    const expected = [_][]const u8{
        "load_steps: 3 here, none in the Godot save",
        "the scene's uid: uid://c8quarrymain1 here, none in the Godot save",
        "ext_resource res://icon.svg: id Texture2D_icon here, 1_kqc8k in the Godot save",
        "ext_resource res://icon.svg: uid uid://bc628hhe4x5yp here, none in the Godot save",
        "sub_resource StyleBoxFlat_a: 2 field(s) here, 1 in the Godot save, which drops fields left at their default",
        "[connection signal=\"ready\" from=\".\" to=\".\" method=\"_on_ready\"] here only",
    };
    try std.testing.expectEqual(expected.len, skipped.len);
    for (expected, skipped) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 0), (try skippedGodotSaveDifferences(allocator, &here, &here)).len);
}
