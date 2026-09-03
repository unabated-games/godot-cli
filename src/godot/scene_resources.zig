//! Add and remove `ext_resource` / `sub_resource` sections in scene documents.

const std = @import("std");
const document = @import("text_format/document.zig");
const save_prepare = @import("text_format/save_prepare.zig");
const tag = @import("text_format/tag.zig");
const scene_id = @import("scene_id.zig");

pub const Error = error{
    OutOfMemory,
    ResourceNotFound,
    DuplicateExtPath,
    DuplicateResourceId,
    ResourceInUse,
    InvalidResourceKind,
} || document.EditError || scene_id.Error;

pub const ConflictDetails = struct {
    kind: []const u8,
    section_name: []const u8,
    id: []const u8,
    path: []const u8,
    existing_section_index: usize,
    existing_line: u32,
};

pub threadlocal var last_conflict: ?ConflictDetails = null;
var last_conflict_id_owned: ?[]u8 = null;
var last_conflict_path_owned: ?[]u8 = null;

pub fn clearConflictDetails() void {
    last_conflict = null;
}

pub fn releaseConflictDetails(allocator: std.mem.Allocator) void {
    if (last_conflict_id_owned) |owned| allocator.free(owned);
    if (last_conflict_path_owned) |owned| allocator.free(owned);
    last_conflict_id_owned = null;
    last_conflict_path_owned = null;
    last_conflict = null;
}

pub fn recordConflict(
    allocator: std.mem.Allocator,
    kind: []const u8,
    section_name: []const u8,
    id: []const u8,
    path: []const u8,
    doc: *const document.Document,
    existing_section_index: usize,
) Error!void {
    if (last_conflict_id_owned) |owned| allocator.free(owned);
    if (last_conflict_path_owned) |owned| allocator.free(owned);
    last_conflict_id_owned = try allocator.dupe(u8, id);
    last_conflict_path_owned = try allocator.dupe(u8, path);

    const line = if (existing_section_index < doc.sections.items.len)
        doc.sections.items[existing_section_index].line
    else
        0;
    last_conflict = .{
        .kind = kind,
        .section_name = section_name,
        .id = last_conflict_id_owned.?,
        .path = last_conflict_path_owned.?,
        .existing_section_index = existing_section_index,
        .existing_line = @intCast(line),
    };
}

pub fn conflictDetailsJson(allocator: std.mem.Allocator) Error!?std.json.ObjectMap {
    const conflict = last_conflict orelse return null;
    var details: std.json.ObjectMap = .{};
    try details.put(allocator, "conflict_kind", .{ .string = conflict.kind });
    try details.put(allocator, "section_name", .{ .string = conflict.section_name });
    try details.put(allocator, "id", .{ .string = conflict.id });
    try details.put(allocator, "path", .{ .string = conflict.path });
    try details.put(allocator, "existing_section_index", .{ .integer = @intCast(conflict.existing_section_index) });
    try details.put(allocator, "existing_line", .{ .integer = @intCast(conflict.existing_line) });
    return details;
}

pub const PropertyInput = struct {
    name: []const u8,
    value: []const u8,
};

pub const AddExtResult = struct {
    section_index: usize,
    id: []const u8,
    res_type: []const u8,
    path: []const u8,

    pub fn deinit(self: *const AddExtResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.res_type);
        allocator.free(self.path);
    }
};

pub const AddSubResult = struct {
    section_index: usize,
    id: []const u8,
    res_type: []const u8,

    pub fn deinit(self: *const AddSubResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.res_type);
    }
};

pub const Referrer = struct {
    section_index: usize,
    section_name: []const u8,
    property_raw: []const u8,
    reference_kind: ReferenceKind,

    pub fn deinit(self: *const Referrer, allocator: std.mem.Allocator) void {
        allocator.free(self.section_name);
        allocator.free(self.property_raw);
    }
};

pub const ReferenceKind = enum {
    ext,
    sub,
};

pub fn seedResourceIds(seed_path: []const u8) void {
    scene_id.resetSceneUniqueIdGenerator();
    scene_id.seedSceneUniqueIdFromPath(seed_path);
}

pub fn findExtResourceByPath(doc: *const document.Document, path: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        if (section.header.getString("path")) |existing| {
            if (std.mem.eql(u8, existing, path)) return index;
        }
    }
    return null;
}

pub fn getOrAddExtResource(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    res_type: []const u8,
    path: []const u8,
    scene_uid: ?[]const u8,
) Error!AddExtResult {
    if (findExtResourceByPath(doc, path)) |section_index| {
        const section = &doc.sections.items[section_index];
        const id = section.header.getString("id") orelse return error.InvalidResourceKind;
        if (scene_uid) |uid| {
            try section.header.setStringField(allocator, "uid", uid);
        }
        return .{
            .section_index = section_index,
            .id = try allocator.dupe(u8, id),
            .res_type = try allocator.dupe(u8, res_type),
            .path = try allocator.dupe(u8, path),
        };
    }

    const added = try addExtResource(allocator, doc, seed_path, res_type, path);
    if (scene_uid) |uid| {
        try doc.sections.items[added.section_index].header.setStringField(allocator, "uid", uid);
    }
    return added;
}

pub fn getOrAddExtResourceWithId(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    res_type: []const u8,
    path: []const u8,
    id: []const u8,
    scene_uid: ?[]const u8,
) Error!AddExtResult {
    if (findExtResourceByPath(doc, path)) |section_index| {
        const section = &doc.sections.items[section_index];
        const existing_id = section.header.getString("id") orelse return error.InvalidResourceKind;
        if (scene_uid) |uid| {
            try section.header.setStringField(allocator, "uid", uid);
        }
        return .{
            .section_index = section_index,
            .id = try allocator.dupe(u8, existing_id),
            .res_type = try allocator.dupe(u8, res_type),
            .path = try allocator.dupe(u8, path),
        };
    }

    seedResourceIds(seed_path);
    return addExtResourceWithId(allocator, doc, res_type, path, id, scene_uid);
}

pub fn addExtResource(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    res_type: []const u8,
    path: []const u8,
) Error!AddExtResult {
    seedResourceIds(seed_path);
    const ext_index = countSections(doc, "ext_resource") + 1;
    const generated_id = try scene_id.formatExtResourceId(allocator, @intCast(ext_index));
    defer allocator.free(generated_id);
    return addExtResourceWithId(allocator, doc, res_type, path, generated_id, null);
}

pub fn addExtResourceWithId(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    res_type: []const u8,
    path: []const u8,
    id: []const u8,
    scene_uid: ?[]const u8,
) Error!AddExtResult {
    clearConflictDetails();
    if (findExtResourceByPath(doc, path)) |section_index| {
        const section = &doc.sections.items[section_index];
        const existing_id = section.header.getString("id") orelse "";
        try recordConflict(allocator, "duplicate_ext_path", "ext_resource", id, path, doc, section_index);
        _ = existing_id;
        return error.DuplicateExtPath;
    }
    if (findResourceSectionIndex(doc, "ext_resource", id)) |section_index| {
        try recordConflict(allocator, "duplicate_resource_id", "ext_resource", id, path, doc, section_index);
        return error.DuplicateResourceId;
    }

    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "ext_resource"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "type", res_type);
    try header.setStringField(allocator, "path", path);
    try header.setStringField(allocator, "id", id_copy);
    if (scene_uid) |uid| try header.setStringField(allocator, "uid", uid);

    const section_index = try insertResourceSection(allocator, doc, "ext_resource", .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });

    try save_prepare.updateLoadSteps(allocator, doc);

    return .{
        .section_index = section_index,
        .id = id_copy,
        .res_type = try allocator.dupe(u8, res_type),
        .path = try allocator.dupe(u8, path),
    };
}

pub fn addSubResource(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    res_type: []const u8,
    properties: []const PropertyInput,
) Error!AddSubResult {
    seedResourceIds(seed_path);
    const generated_id = try scene_id.formatSubResourceId(allocator, res_type);
    defer allocator.free(generated_id);
    return addSubResourceWithId(allocator, doc, res_type, generated_id, properties);
}

pub fn addSubResourceWithId(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    res_type: []const u8,
    id: []const u8,
    properties: []const PropertyInput,
) Error!AddSubResult {
    clearConflictDetails();
    if (findResourceSectionIndex(doc, "sub_resource", id)) |section_index| {
        try recordConflict(allocator, "duplicate_resource_id", "sub_resource", id, "", doc, section_index);
        return error.DuplicateResourceId;
    }

    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "sub_resource"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "type", res_type);
    try header.setStringField(allocator, "id", id_copy);

    const section_index = try insertResourceSection(allocator, doc, "sub_resource", .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });

    for (properties) |prop| {
        try document.setSectionProperty(doc, allocator, section_index, prop.name, prop.value);
    }

    try save_prepare.updateLoadSteps(allocator, doc);

    return .{
        .section_index = section_index,
        .id = id_copy,
        .res_type = try allocator.dupe(u8, res_type),
    };
}

pub fn removeExtResource(allocator: std.mem.Allocator, doc: *document.Document, id: []const u8) Error!usize {
    return try removeResource(allocator, doc, "ext_resource", id, .ext);
}

pub fn removeSubResource(allocator: std.mem.Allocator, doc: *document.Document, id: []const u8) Error!usize {
    return try removeResource(allocator, doc, "sub_resource", id, .sub);
}

pub fn findReferrers(allocator: std.mem.Allocator, doc: *const document.Document, id: []const u8, kind: ReferenceKind) Error![]Referrer {
    var items: std.ArrayList(Referrer) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    const prefix = switch (kind) {
        .ext => "ExtResource(\"",
        .sub => "SubResource(\"",
    };
    const needle = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, id });
    defer allocator.free(needle);

    for (doc.sections.items, 0..) |section, section_index| {
        for (section.properties.items) |prop| {
            if (std.mem.indexOf(u8, prop.raw, needle) == null) continue;
            try items.append(allocator, .{
                .section_index = section_index,
                .section_name = try allocator.dupe(u8, section.header.name),
                .property_raw = try allocator.dupe(u8, prop.raw),
                .reference_kind = kind,
            });
        }
    }

    return try items.toOwnedSlice(allocator);
}

fn removeResource(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    section_name: []const u8,
    id: []const u8,
    kind: ReferenceKind,
) Error!usize {
    const section_index = findResourceSectionIndex(doc, section_name, id) orelse return error.ResourceNotFound;

    const referrers = try findReferrers(allocator, doc, id, kind);
    defer {
        for (referrers) |*ref| ref.deinit(allocator);
        allocator.free(referrers);
    }
    if (referrers.len > 0) return error.ResourceInUse;

    var section = try document.removeSection(doc, section_index);
    section.deinit(allocator);
    try save_prepare.updateLoadSteps(allocator, doc);
    return section_index;
}

fn insertResourceSection(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    section_name: []const u8,
    section: document.Section,
) Error!usize {
    const insert_at = findResourceInsertIndex(doc, section_name);
    try document.insertSection(doc, allocator, insert_at, section);
    return insert_at;
}

/// Godot requires `ext_resource` sections before `sub_resource` sections.
fn findResourceInsertIndex(doc: *const document.Document, section_name: []const u8) usize {
    if (std.mem.eql(u8, section_name, "ext_resource")) {
        var last_ext: ?usize = null;
        for (doc.sections.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.header.name, "ext_resource")) last_ext = index;
        }
        if (last_ext) |index| return index + 1;

        for (doc.sections.items, 0..) |item, index| {
            if (index == 0) continue;
            const name = item.header.name;
            if (std.mem.eql(u8, name, "gd_scene") or std.mem.eql(u8, name, "gd_resource")) continue;
            if (std.mem.eql(u8, name, "ext_resource")) continue;
            return index;
        }
        return doc.sections.items.len;
    }

    if (std.mem.eql(u8, section_name, "sub_resource")) {
        var last_sub: ?usize = null;
        for (doc.sections.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.header.name, "sub_resource")) last_sub = index;
        }
        if (last_sub) |index| return index + 1;

        var last_ext: ?usize = null;
        for (doc.sections.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.header.name, "ext_resource")) last_ext = index;
        }
        if (last_ext) |index| return index + 1;

        return firstBodySectionIndex(doc);
    }

    return firstBodySectionIndex(doc);
}

/// Where resources stop and the body starts: the first `[node]` in a scene,
/// the `[resource]` section in a .tres. Sub-resources appended after the
/// `[resource]` body used to land there for a .tres with no other resources.
fn firstBodySectionIndex(doc: *const document.Document) usize {
    for (doc.sections.items, 0..) |item, index| {
        if (std.mem.eql(u8, item.header.name, "node") or std.mem.eql(u8, item.header.name, "resource")) return index;
    }
    return doc.sections.items.len;
}

fn findResourceSectionIndex(doc: *const document.Document, section_name: []const u8, id: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, section_name)) continue;
        if (section.header.getString("id")) |existing| {
            if (std.mem.eql(u8, existing, id)) return index;
        }
    }
    return null;
}

fn countSections(doc: *const document.Document, section_name: []const u8) usize {
    var total: usize = 0;
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, section_name)) total += 1;
    }
    return total;
}

test "ext_resource inserts before sub_resource" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[sub_resource type="CapsuleShape2D" id="CapsuleShape2D_shape"]
        \\radius = 8
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var ext = try addExtResource(allocator, &doc, "res://main.tscn", "Texture2D", "res://icon.svg");
    defer ext.deinit(allocator);

    try std.testing.expectEqualStrings("ext_resource", doc.sections.items[1].header.name);
    try std.testing.expectEqualStrings("sub_resource", doc.sections.items[2].header.name);
    try std.testing.expectEqualStrings("node", doc.sections.items[3].header.name);
}

test "add ext and sub resources with load_steps" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=1 format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var ext = try addExtResource(allocator, &doc, "res://main.tscn", "Script", "res://player.gd");
    defer ext.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, ext.id, "1_"));

    var sub = try addSubResource(allocator, &doc, "res://main.tscn", "RectangleShape2D", &.{
        .{ .name = "size", .value = "Vector2(16, 32)" },
    });
    defer sub.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, sub.id, "RectangleShape2D_"));

    try std.testing.expectEqual(@as(usize, 1), findResourceSectionIndex(&doc, "ext_resource", ext.id).?);
    try std.testing.expectEqual(@as(usize, 2), findResourceSectionIndex(&doc, "sub_resource", sub.id).?);
    try std.testing.expectEqual(@as(i64, 3), doc.sections.items[0].header.getInteger("load_steps").?);
    try std.testing.expectEqualStrings("size = Vector2(16, 32)", doc.sections.items[sub.section_index].properties.items[0].raw);
}

test "remove sub resource refuses when referenced" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=3 format=3]
        \\
        \\[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_test1"]
        \\radius = 0.5
        \\
        \\[node name="Root" type="Node3D"]
        \\
        \\[node name="Collision" type="CollisionShape3D" parent="."]
        \\shape = SubResource("CapsuleShape3D_test1")
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try std.testing.expectError(error.ResourceInUse, removeSubResource(allocator, &doc, "CapsuleShape3D_test1"));
}

test "remove ext resource when unused" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="Script" path="res://unused.gd" id="1_unused"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    _ = try removeExtResource(allocator, &doc, "1_unused");
    try std.testing.expectEqual(@as(usize, 2), doc.sections.items.len);
    // Godot never writes load_steps=1, so the field goes with the last resource.
    try std.testing.expect(doc.sections.items[0].header.getInteger("load_steps") == null);
}
