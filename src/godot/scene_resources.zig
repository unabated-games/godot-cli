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
    ResourceInUse,
    InvalidResourceKind,
} || document.EditError;

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

pub fn addExtResource(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    res_type: []const u8,
    path: []const u8,
) Error!AddExtResult {
    if (findExtResourceByPath(doc, path) != null) return error.DuplicateExtPath;

    seedResourceIds(seed_path);
    const ext_index = countSections(doc, "ext_resource") + 1;
    const id = try scene_id.formatExtResourceId(allocator, @intCast(ext_index));
    errdefer allocator.free(id);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "ext_resource"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "type", res_type);
    try header.setStringField(allocator, "path", path);
    try header.setStringField(allocator, "id", id);

    const section_index = try insertResourceSection(allocator, doc, "ext_resource", .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });

    save_prepare.updateLoadSteps(doc);

    return .{
        .section_index = section_index,
        .id = id,
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
    const id = try scene_id.formatSubResourceId(allocator, res_type);
    errdefer allocator.free(id);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "sub_resource"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "type", res_type);
    try header.setStringField(allocator, "id", id);

    const section_index = try insertResourceSection(allocator, doc, "sub_resource", .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });

    for (properties) |prop| {
        try document.setSectionProperty(doc, allocator, section_index, prop.name, prop.value);
    }

    save_prepare.updateLoadSteps(doc);

    return .{
        .section_index = section_index,
        .id = id,
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
    save_prepare.updateLoadSteps(doc);
    return section_index;
}

fn insertResourceSection(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    section_name: []const u8,
    section: document.Section,
) Error!usize {
    const insert_at = blk: {
        var last_same: ?usize = null;
        var first_node: ?usize = null;
        for (doc.sections.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.header.name, section_name)) last_same = index;
            if (first_node == null and std.mem.eql(u8, item.header.name, "node")) first_node = index;
        }
        if (last_same) |index| break :blk index + 1;
        if (first_node) |index| break :blk index;
        break :blk doc.sections.items.len;
    };

    try document.insertSection(doc, allocator, insert_at, section);
    return insert_at;
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

fn findExtResourceByPath(doc: *const document.Document, path: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        if (section.header.getString("path")) |existing| {
            if (std.mem.eql(u8, existing, path)) return index;
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
    try std.testing.expectEqual(@as(i64, 1), doc.sections.items[0].header.getInteger("load_steps").?);
}
