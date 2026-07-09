//! Compare node trees and node properties between two scene documents.

const std = @import("std");
const document = @import("text_format/document.zig");
const node_tree = @import("node_tree.zig");

pub const Error = error{OutOfMemory} || node_tree.Error;

pub const DiffItem = struct {
    kind: []const u8,
    path: []const u8,
    type_a: ?[]const u8 = null,
    type_b: ?[]const u8 = null,

    pub fn deinit(self: *const DiffItem, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
        if (self.type_a) |t| allocator.free(t);
        if (self.type_b) |t| allocator.free(t);
    }
};

pub const PropertyDiffItem = struct {
    kind: []const u8,
    path: []const u8,
    property: []const u8,
    value_a: ?[]const u8 = null,
    value_b: ?[]const u8 = null,

    pub fn deinit(self: *const PropertyDiffItem, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
        allocator.free(self.property);
        if (self.value_a) |v| allocator.free(v);
        if (self.value_b) |v| allocator.free(v);
    }
};

pub const DiffOptions = struct {
    include_properties: bool = false,
};

pub const DiffResult = struct {
    nodes: []DiffItem,
    properties: []PropertyDiffItem,
    identical: bool,
    node_count_a: usize,
    node_count_b: usize,

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        for (self.nodes) |*item| item.deinit(allocator);
        allocator.free(self.nodes);
        for (self.properties) |*item| item.deinit(allocator);
        allocator.free(self.properties);
    }
};

pub fn diffDocuments(
    allocator: std.mem.Allocator,
    doc_a: *const document.Document,
    doc_b: *const document.Document,
    options: DiffOptions,
) Error!DiffResult {
    var list_a = try node_tree.collectNodes(allocator, doc_a);
    defer list_a.deinit(allocator);
    var list_b = try node_tree.collectNodes(allocator, doc_b);
    defer list_b.deinit(allocator);
    return diffNodeLists(allocator, doc_a, doc_b, &list_a, &list_b, options);
}

pub fn diffToObjectMap(allocator: std.mem.Allocator, diff: *const DiffResult) Error!std.json.ObjectMap {
    var nodes_json = std.json.Array.init(allocator);
    for (diff.nodes) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "kind", .{ .string = try allocator.dupe(u8, item.kind) });
        try row.put(allocator, "path", .{ .string = try allocator.dupe(u8, item.path) });
        if (item.type_a) |type_a| {
            try row.put(allocator, "type_a", .{ .string = try allocator.dupe(u8, type_a) });
        }
        if (item.type_b) |type_b| {
            try row.put(allocator, "type_b", .{ .string = try allocator.dupe(u8, type_b) });
        }
        try nodes_json.append(.{ .object = row });
    }

    var properties_json = std.json.Array.init(allocator);
    for (diff.properties) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "kind", .{ .string = try allocator.dupe(u8, item.kind) });
        try row.put(allocator, "path", .{ .string = try allocator.dupe(u8, item.path) });
        try row.put(allocator, "property", .{ .string = try allocator.dupe(u8, item.property) });
        if (item.value_a) |value_a| {
            try row.put(allocator, "value_a", .{ .string = try allocator.dupe(u8, value_a) });
        }
        if (item.value_b) |value_b| {
            try row.put(allocator, "value_b", .{ .string = try allocator.dupe(u8, value_b) });
        }
        try properties_json.append(.{ .object = row });
    }

    const total_diffs = diff.nodes.len + diff.properties.len;

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "identical", .{ .bool = diff.identical });
    try data.put(allocator, "node_count_a", .{ .integer = @intCast(diff.node_count_a) });
    try data.put(allocator, "node_count_b", .{ .integer = @intCast(diff.node_count_b) });
    try data.put(allocator, "node_diff_count", .{ .integer = @intCast(diff.nodes.len) });
    try data.put(allocator, "property_diff_count", .{ .integer = @intCast(diff.properties.len) });
    try data.put(allocator, "diff_count", .{ .integer = @intCast(total_diffs) });
    try data.put(allocator, "nodes", .{ .array = nodes_json });
    try data.put(allocator, "properties", .{ .array = properties_json });
    return data;
}

pub fn diffNodeLists(
    allocator: std.mem.Allocator,
    doc_a: *const document.Document,
    doc_b: *const document.Document,
    list_a: *const node_tree.NodeList,
    list_b: *const node_tree.NodeList,
    options: DiffOptions,
) Error!DiffResult {
    var map_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer map_a.deinit(allocator);
    var map_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer map_b.deinit(allocator);
    var index_a: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer index_a.deinit(allocator);
    var index_b: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer index_b.deinit(allocator);

    for (list_a.nodes) |*node| {
        try map_a.put(allocator, node.path, node.node_type);
        try index_a.put(allocator, node.path, node.section_index);
    }
    for (list_b.nodes) |*node| {
        try map_b.put(allocator, node.path, node.node_type);
        try index_b.put(allocator, node.path, node.section_index);
    }

    var node_items: std.ArrayList(DiffItem) = .empty;
    errdefer {
        for (node_items.items) |*item| item.deinit(allocator);
        node_items.deinit(allocator);
    }

    for (list_a.nodes) |*node| {
        const type_b = map_b.get(node.path);
        if (type_b == null) {
            try node_items.append(allocator, .{
                .kind = try allocator.dupe(u8, "removed"),
                .path = try allocator.dupe(u8, node.path),
                .type_a = try allocator.dupe(u8, node.node_type),
                .type_b = null,
            });
            continue;
        }
        if (!std.mem.eql(u8, node.node_type, type_b.?)) {
            try node_items.append(allocator, .{
                .kind = try allocator.dupe(u8, "type_changed"),
                .path = try allocator.dupe(u8, node.path),
                .type_a = try allocator.dupe(u8, node.node_type),
                .type_b = try allocator.dupe(u8, type_b.?),
            });
        }
    }

    for (list_b.nodes) |*node| {
        if (map_a.get(node.path) == null) {
            try node_items.append(allocator, .{
                .kind = try allocator.dupe(u8, "added"),
                .path = try allocator.dupe(u8, node.path),
                .type_a = null,
                .type_b = try allocator.dupe(u8, node.node_type),
            });
        }
    }

    var property_items: std.ArrayList(PropertyDiffItem) = .empty;
    errdefer {
        for (property_items.items) |*item| item.deinit(allocator);
        property_items.deinit(allocator);
    }

    if (options.include_properties) {
        for (list_a.nodes) |*node| {
            if (index_b.get(node.path) == null) continue;
            const section_a = doc_a.sections.items[node.section_index];
            const section_b = doc_b.sections.items[index_b.get(node.path).?];
            try diffSectionProperties(allocator, node.path, &section_a, &section_b, &property_items);
        }
    }

    const owned_nodes = try node_items.toOwnedSlice(allocator);
    const owned_properties = try property_items.toOwnedSlice(allocator);
    return .{
        .nodes = owned_nodes,
        .properties = owned_properties,
        .identical = owned_nodes.len == 0 and owned_properties.len == 0,
        .node_count_a = list_a.nodes.len,
        .node_count_b = list_b.nodes.len,
    };
}

fn diffSectionProperties(
    allocator: std.mem.Allocator,
    node_path: []const u8,
    section_a: *const document.Section,
    section_b: *const document.Section,
    out: *std.ArrayList(PropertyDiffItem),
) Error!void {
    var props_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer props_a.deinit(allocator);
    var props_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer props_b.deinit(allocator);

    for (section_a.properties.items) |prop| {
        const name = propertyName(prop.raw) orelse continue;
        const value = propertyValue(prop.raw);
        try props_a.put(allocator, name, value);
    }
    for (section_b.properties.items) |prop| {
        const name = propertyName(prop.raw) orelse continue;
        const value = propertyValue(prop.raw);
        try props_b.put(allocator, name, value);
    }

    for (props_a.keys()) |name| {
        const value_a = props_a.get(name).?;
        const value_b = props_b.get(name);
        if (value_b == null) {
            try out.append(allocator, .{
                .kind = try allocator.dupe(u8, "property_removed"),
                .path = try allocator.dupe(u8, node_path),
                .property = try allocator.dupe(u8, name),
                .value_a = try allocator.dupe(u8, value_a),
                .value_b = null,
            });
            continue;
        }
        if (!std.mem.eql(u8, value_a, value_b.?)) {
            try out.append(allocator, .{
                .kind = try allocator.dupe(u8, "property_changed"),
                .path = try allocator.dupe(u8, node_path),
                .property = try allocator.dupe(u8, name),
                .value_a = try allocator.dupe(u8, value_a),
                .value_b = try allocator.dupe(u8, value_b.?),
            });
        }
    }

    for (props_b.keys()) |name| {
        if (props_a.get(name) == null) {
            try out.append(allocator, .{
                .kind = try allocator.dupe(u8, "property_added"),
                .path = try allocator.dupe(u8, node_path),
                .property = try allocator.dupe(u8, name),
                .value_a = null,
                .value_b = try allocator.dupe(u8, props_b.get(name).?),
            });
        }
    }
}

fn propertyName(raw: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return raw[0..sep];
}

fn propertyValue(raw: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, raw, " = ") orelse return raw;
    return std.mem.trim(u8, raw[sep + 3 ..], &std.ascii.whitespace);
}

test "diff detects added and removed nodes" {
    const allocator = std.testing.allocator;
    const scene_a =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="."]
        \\
    ;
    const scene_b =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="HUD" type="CanvasLayer" parent="."]
        \\
    ;

    var doc_a = try document.parseBytes(allocator, scene_a);
    defer doc_a.deinit(allocator);
    var doc_b = try document.parseBytes(allocator, scene_b);
    defer doc_b.deinit(allocator);

    var diff = try diffDocuments(allocator, &doc_a, &doc_b, .{});
    defer diff.deinit(allocator);

    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 2), diff.nodes.len);
}

test "identical scenes produce empty diff" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;

    var doc_a = try document.parseBytes(allocator, source);
    defer doc_a.deinit(allocator);
    var doc_b = try document.parseBytes(allocator, source);
    defer doc_b.deinit(allocator);

    var diff = try diffDocuments(allocator, &doc_a, &doc_b, .{});
    defer diff.deinit(allocator);

    try std.testing.expect(diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.nodes.len);
}

test "property diff detects changed values" {
    const allocator = std.testing.allocator;
    const scene_a =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\visible = true
        \\
    ;
    const scene_b =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\visible = false
        \\z_index = 1
        \\
    ;

    var doc_a = try document.parseBytes(allocator, scene_a);
    defer doc_a.deinit(allocator);
    var doc_b = try document.parseBytes(allocator, scene_b);
    defer doc_b.deinit(allocator);

    var diff = try diffDocuments(allocator, &doc_a, &doc_b, .{ .include_properties = true });
    defer diff.deinit(allocator);

    try std.testing.expect(!diff.identical);
    try std.testing.expect(diff.properties.len >= 2);
}
