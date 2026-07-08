//! Normalize parsed documents toward Godot 4.x headless/editor text save output.
//! Godot omits some header fields and default sub_resource property values.

const std = @import("std");
const document = @import("document.zig");

pub const DefaultProperty = struct {
    key: []const u8,
    value: []const u8,
};

/// Default property values Godot omits on save (matched on parsed key/value).
fn defaultPropertiesForType(type_name: []const u8) ?[]const DefaultProperty {
    if (std.mem.eql(u8, type_name, "CapsuleShape3D")) {
        return &.{
            .{ .key = "radius", .value = "0.5" },
            .{ .key = "height", .value = "2.0" },
        };
    }
    return null;
}

pub fn applyGodotSaveFormat(allocator: std.mem.Allocator, doc: *document.Document) !void {
    stripSceneHeaderMetadata(allocator, doc);
    try stripDefaultSubResourceProperties(allocator, doc);
    normalizeBlankLines(doc);
}

fn stripSceneHeaderMetadata(allocator: std.mem.Allocator, doc: *document.Document) void {
    for (doc.sections.items) |*section| {
        if (std.mem.eql(u8, section.header.name, "gd_scene") or std.mem.eql(u8, section.header.name, "gd_resource")) {
            section.header.removeField(allocator, "load_steps");
            section.header.removeField(allocator, "uid");
            return;
        }
    }
}

fn stripDefaultSubResourceProperties(allocator: std.mem.Allocator, doc: *document.Document) !void {
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
        const type_name = section.header.getString("type") orelse continue;
        const defaults = defaultPropertiesForType(type_name) orelse continue;

        var write_index: usize = 0;
        for (section.properties.items) |prop| {
            if (isDefaultProperty(prop.raw, defaults)) {
                allocator.free(prop.raw);
                continue;
            }
            section.properties.items[write_index] = prop;
            write_index += 1;
        }
        section.properties.shrinkRetainingCapacity(write_index);
    }
}

fn isDefaultProperty(raw: []const u8, defaults: []const DefaultProperty) bool {
    const key = propertyKey(raw) orelse return false;
    const value = propertyValue(raw) orelse return false;
    for (defaults) |def| {
        if (std.mem.eql(u8, key, def.key) and std.mem.eql(u8, value, def.value)) return true;
    }
    return false;
}

fn propertyKey(raw: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return std.mem.trim(u8, raw[0..eq], &std.ascii.whitespace);
}

fn propertyValue(raw: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return std.mem.trim(u8, raw[eq + 3 ..], &std.ascii.whitespace);
}

/// Godot inserts a single blank line before every section after the first.
fn normalizeBlankLines(doc: *document.Document) void {
    for (doc.sections.items[1..], 1..) |*section, index| {
        _ = index;
        section.leading_blank_lines = 1;
    }
}

test "strips Godot-omitted scene metadata and defaults" {
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
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try applyGodotSaveFormat(allocator, &doc);

    try std.testing.expect(doc.sections.items[0].header.getInteger("load_steps") == null);
    try std.testing.expect(doc.sections.items[0].header.getString("uid") == null);
    try std.testing.expectEqual(@as(usize, 0), doc.sections.items[2].properties.items.len);
}
