//! Scene node tree: list nodes and resolve paths from parsed `.tscn` documents.

const std = @import("std");
const document = @import("text_format/document.zig");

pub const Error = error{
    OutOfMemory,
    NoSceneRoot,
    NodeNotFound,
    AmbiguousNodeName,
};

pub const NodeInfo = struct {
    name: []const u8,
    node_type: []const u8,
    /// Parent attribute from the file (`"."`, `"Root"`, `"Root/Arm"`, …). Empty for scene root.
    parent: []const u8,
    /// Viewport-style path, e.g. `/root/Root/Collision`.
    path: []const u8,
    section_line: usize,
    unique_id: ?i64,

    pub fn deinit(self: *const NodeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.node_type);
        allocator.free(self.parent);
        allocator.free(self.path);
    }
};

pub const NodeList = struct {
    nodes: []NodeInfo,

    pub fn deinit(self: *NodeList, allocator: std.mem.Allocator) void {
        for (self.nodes) |*node| node.deinit(allocator);
        allocator.free(self.nodes);
    }
};

const RawNode = struct {
    name: []const u8,
    node_type: []const u8,
    parent_attr: ?[]const u8,
    section_line: usize,
    unique_id: ?i64,
};

pub fn collectNodes(allocator: std.mem.Allocator, doc: *const document.Document) Error!NodeList {
    var raw_nodes: std.ArrayList(RawNode) = .empty;
    defer raw_nodes.deinit(allocator);
    errdefer raw_nodes.deinit(allocator);

    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "node")) continue;
        const name = section.header.getString("name") orelse continue;
        const node_type = section.header.getString("type") orelse "";
        const parent_attr = section.header.getString("parent");
        const unique_id = section.header.getInteger("unique_id");
        try raw_nodes.append(allocator, .{
            .name = name,
            .node_type = node_type,
            .parent_attr = parent_attr,
            .section_line = section.line,
            .unique_id = unique_id,
        });
    }

    if (raw_nodes.items.len == 0) {
        return .{ .nodes = try allocator.alloc(NodeInfo, 0) };
    }

    const scene_root_name = blk: {
        for (raw_nodes.items) |node| {
            if (node.parent_attr == null) break :blk node.name;
        }
        return error.NoSceneRoot;
    };

    const nodes = try allocator.alloc(NodeInfo, raw_nodes.items.len);
    errdefer {
        for (nodes) |*node| node.deinit(allocator);
        allocator.free(nodes);
    }

    for (raw_nodes.items, 0..) |raw, index| {
        const parent_copy = if (raw.parent_attr) |parent|
            try allocator.dupe(u8, parent)
        else
            try allocator.dupe(u8, "");
        errdefer allocator.free(parent_copy);

        const path = try buildNodePath(allocator, scene_root_name, raw.parent_attr, raw.name);
        errdefer allocator.free(path);

        nodes[index] = .{
            .name = try allocator.dupe(u8, raw.name),
            .node_type = try allocator.dupe(u8, raw.node_type),
            .parent = parent_copy,
            .path = path,
            .section_line = raw.section_line,
            .unique_id = raw.unique_id,
        };
    }

    return .{ .nodes = nodes };
}

pub fn findByPath(list: *const NodeList, path: []const u8) ?*const NodeInfo {
    for (list.nodes) |*node| {
        if (std.mem.eql(u8, node.path, path)) return node;
    }
    return null;
}

pub fn findByName(
    list: *const NodeList,
    node_name: []const u8,
    parent_filter: ?[]const u8,
) Error!?*const NodeInfo {
    var match: ?*const NodeInfo = null;
    for (list.nodes) |*node| {
        if (!std.mem.eql(u8, node.name, node_name)) continue;
        if (parent_filter) |parent| {
            if (!std.mem.eql(u8, node.parent, parent)) continue;
        }
        if (match != null) return error.AmbiguousNodeName;
        match = node;
    }
    return match;
}

pub fn nodeToJson(allocator: std.mem.Allocator, node: *const NodeInfo) !std.json.Value {
    var row: std.json.ObjectMap = .{};
    try row.put(allocator, "name", .{ .string = try allocator.dupe(u8, node.name) });
    try row.put(allocator, "type", .{ .string = try allocator.dupe(u8, node.node_type) });
    if (node.parent.len > 0) {
        try row.put(allocator, "parent", .{ .string = try allocator.dupe(u8, node.parent) });
    }
    try row.put(allocator, "path", .{ .string = try allocator.dupe(u8, node.path) });
    try row.put(allocator, "section_line", .{ .integer = @intCast(node.section_line) });
    if (node.unique_id) |id| {
        try row.put(allocator, "unique_id", .{ .integer = id });
    }
    return .{ .object = row };
}

pub fn nodesToJsonArray(allocator: std.mem.Allocator, nodes: []const NodeInfo) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (nodes) |*node| {
        try arr.append(try nodeToJson(allocator, node));
    }
    return arr;
}

fn buildNodePath(
    allocator: std.mem.Allocator,
    scene_root_name: []const u8,
    parent_attr: ?[]const u8,
    node_name: []const u8,
) Error![]u8 {
    if (parent_attr == null) {
        return try std.fmt.allocPrint(allocator, "/root/{s}", .{node_name});
    }
    const parent = parent_attr.?;
    if (std.mem.eql(u8, parent, ".") or std.mem.eql(u8, parent, scene_root_name)) {
        return try std.fmt.allocPrint(allocator, "/root/{s}/{s}", .{ scene_root_name, node_name });
    }
    return try std.fmt.allocPrint(allocator, "/root/{s}/{s}/{s}", .{ scene_root_name, parent, node_name });
}

test "collect nodes from sample scene bytes" {
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

    var list = try collectNodes(allocator, &doc);
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), list.nodes.len);

    try std.testing.expectEqualStrings("Root", list.nodes[0].name);
    try std.testing.expectEqualStrings("/root/Root", list.nodes[0].path);
    try std.testing.expectEqual(@as(usize, 0), list.nodes[0].parent.len);
    try std.testing.expectEqual(@as(?i64, 1290995245), list.nodes[0].unique_id);

    try std.testing.expectEqualStrings("Collision", list.nodes[1].name);
    try std.testing.expectEqualStrings("Root", list.nodes[1].parent);
    try std.testing.expectEqualStrings("/root/Root/Collision", list.nodes[1].path);
    try std.testing.expectEqual(@as(?i64, 987654321), list.nodes[1].unique_id);
}

test "find by path and name" {
    const allocator = std.testing.allocator;
    const source =
        \\[node name="Main" type="Node2D"]
        \\[node name="Player" type="CharacterBody2D" parent="."]
        \\[node name="Sprite" type="Sprite2D" parent="Player"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var list = try collectNodes(allocator, &doc);
    defer list.deinit(allocator);

    const player = findByPath(&list, "/root/Main/Player").?;
    try std.testing.expectEqualStrings("Player", player.name);
    try std.testing.expectEqualStrings(".", player.parent);

    const sprite = (try findByName(&list, "Sprite", null)).?;
    try std.testing.expectEqualStrings("/root/Main/Player/Sprite", sprite.path);

    const by_parent = (try findByName(&list, "Player", ".")).?;
    try std.testing.expectEqualStrings("/root/Main/Player", by_parent.path);
}
