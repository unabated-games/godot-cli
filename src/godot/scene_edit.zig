//! Scene tree mutations: create scenes, add/remove/rename/reparent nodes.

const std = @import("std");
const document = @import("text_format/document.zig");
const tag = @import("text_format/tag.zig");
const node_tree = @import("node_tree.zig");
const scene_connections = @import("scene_connections.zig");
const node_section_order = @import("node_section_order.zig");

pub const Error = error{
    OutOfMemory,
    NoSceneRoot,
    NodeNotFound,
    ParentNotFound,
    DuplicateNodeName,
    CannotRemoveRoot,
    CannotReparentRoot,
    ReparentCycle,
    HasChildren,
    InvalidNodePath,
    AmbiguousNodeName,
} || document.EditError || scene_connections.Error;

pub const AddNodeResult = struct {
    section_index: usize,
    path: []const u8,
    parent_attr: []const u8,

    pub fn deinit(self: *const AddNodeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.parent_attr);
    }
};

pub fn createNewScene(allocator: std.mem.Allocator, root_name: []const u8, root_type: []const u8) Error!document.Document {
    var doc = document.Document.init(allocator);
    errdefer doc.deinit(allocator);

    var gd_header = tag.Tag{ .name = try allocator.dupe(u8, "gd_scene"), .fields = .{} };
    errdefer gd_header.deinit(allocator);
    // No load_steps: Godot writes it only when above one, and save
    // preparation adds it before `format` when resources arrive.
    try gd_header.setIntegerField(allocator, "format", 3);

    try doc.sections.append(allocator, .{
        .line = 0,
        .leading_blank_lines = 0,
        .header = gd_header,
        .properties = .empty,
    });

    var root_header = try makeNodeHeader(allocator, root_name, root_type, null);
    errdefer root_header.deinit(allocator);

    try doc.sections.append(allocator, .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = root_header,
        .properties = .empty,
    });

    return doc;
}

/// A new `.tres`: a `gd_resource` header and an empty `[resource]` section.
/// Godot writes `format=3` and no `load_steps` for a resource with nothing
/// else in it, so neither does this.
pub fn createNewResource(allocator: std.mem.Allocator, resource_type: []const u8) Error!document.Document {
    var doc = document.Document.init(allocator);
    errdefer doc.deinit(allocator);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "gd_resource"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "type", resource_type);
    try header.setIntegerField(allocator, "format", 3);
    try doc.sections.append(allocator, .{ .line = 0, .leading_blank_lines = 0, .header = header, .properties = .empty });

    var body = tag.Tag{ .name = try allocator.dupe(u8, "resource"), .fields = .{} };
    errdefer body.deinit(allocator);
    try doc.sections.append(allocator, .{ .line = 0, .leading_blank_lines = 1, .header = body, .properties = .empty });

    return doc;
}

pub fn addNode(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    parent_path: []const u8,
    name: []const u8,
    node_type: []const u8,
) Error!AddNodeResult {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    const parent = node_tree.findByPath(&list, parent_path) orelse return error.ParentNotFound;
    if (hasSiblingName(&list, parent_path, name)) return error.DuplicateNodeName;

    const parent_attr = try viewportPathToParentAttr(allocator, scene_root.name, parent.path);
    errdefer allocator.free(parent_attr);

    var header = try makeNodeHeader(allocator, name, node_type, parent_attr);
    errdefer header.deinit(allocator);

    const insert_at = try node_section_order.insertIndexForNewChild(allocator, doc, parent.path);
    const section_index = blk: {
        const section = document.Section{
            .line = 0,
            .leading_blank_lines = 1,
            .header = header,
            .properties = .empty,
        };
        try document.insertSection(doc, allocator, insert_at, section);
        break :blk insert_at;
    };

    const new_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent.path, name });

    return .{
        .section_index = section_index,
        .path = new_path,
        .parent_attr = parent_attr,
    };
}

pub fn setNodeProperty(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    node_path: []const u8,
    property_name: []const u8,
    property_value: []const u8,
) Error!void {
    const section_index = try findNodeSectionIndex(allocator, doc, node_path);
    try document.setSectionProperty(doc, allocator, section_index, property_name, property_value);
}

pub fn removeNode(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    node_path: []const u8,
    recursive: bool,
) Error!usize {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const target = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;
    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    if (std.mem.eql(u8, target.path, scene_root.path)) return error.CannotRemoveRoot;

    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);

    try indices.append(allocator, try findNodeSectionIndex(allocator, doc, target.path));

    if (!recursive) {
        if (hasDescendantPath(&list, target.path)) return error.HasChildren;
    } else {
        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{target.path});
        defer allocator.free(prefix);
        for (list.nodes) |*node| {
            if (std.mem.startsWith(u8, node.path, prefix)) {
                try indices.append(allocator, try findNodeSectionIndex(allocator, doc, node.path));
            }
        }
    }

    // The editor drops connections to a deleted node; keeping them would leave
    // Godot warning about a missing path on every load.
    const attr_prefix = try nodePathPrefixFromViewport(allocator, scene_root.name, target.path);
    defer allocator.free(attr_prefix);
    const connection_indices = try scene_connections.referencingSectionIndices(allocator, doc, attr_prefix);
    defer allocator.free(connection_indices);
    try indices.appendSlice(allocator, connection_indices);

    std.mem.sort(usize, indices.items, {}, descUsize);

    var removed: usize = 0;
    for (indices.items) |index| {
        var section = try document.removeSection(doc, index);
        section.deinit(allocator);
        removed += 1;
    }

    return removed;
}

pub fn renameNode(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    node_path: []const u8,
    new_name: []const u8,
) Error![]const u8 {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const target = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;
    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    if (std.mem.eql(u8, target.name, new_name)) return try allocator.dupe(u8, target.path);

    const parent_path = try parentViewportPath(allocator, target.path);
    defer if (parent_path) |path| allocator.free(path);

    const parent_for_sibling = parent_path orelse scene_root.path;
    if (hasSiblingName(&list, parent_for_sibling, new_name)) return error.DuplicateNodeName;

    const old_prefix = try nodePathPrefixFromViewport(allocator, scene_root.name, target.path);
    defer allocator.free(old_prefix);

    const section_index = try findNodeSectionIndex(allocator, doc, target.path);
    try doc.sections.items[section_index].header.setStringField(allocator, "name", new_name);

    const new_path = if (parent_path) |parent|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, new_name })
    else
        try std.fmt.allocPrint(allocator, "/root/{s}", .{new_name});

    if (old_prefix.len > 0) {
        const old_with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{old_prefix});
        defer allocator.free(old_with_slash);
        const new_prefix = try nodePathPrefixFromViewport(allocator, scene_root.name, new_path);
        defer allocator.free(new_prefix);

        for (doc.sections.items) |*section| {
            if (!std.mem.eql(u8, section.header.name, "node")) continue;
            const parent_attr = section.header.getString("parent") orelse continue;
            if (std.mem.eql(u8, parent_attr, old_prefix)) {
                try section.header.setStringField(allocator, "parent", new_prefix);
                continue;
            }
            if (std.mem.startsWith(u8, parent_attr, old_with_slash)) {
                const suffix = parent_attr[old_with_slash.len..];
                const rewritten = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ new_prefix, suffix });
                defer allocator.free(rewritten);
                try section.header.setStringField(allocator, "parent", rewritten);
            }
        }
        try scene_connections.rewritePaths(allocator, doc, old_prefix, new_prefix);
    }

    return new_path;
}

pub fn reparentNode(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    node_path: []const u8,
    new_parent_path: []const u8,
) Error!void {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const target = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;
    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    if (std.mem.eql(u8, target.path, scene_root.path)) return error.CannotReparentRoot;

    const new_parent = node_tree.findByPath(&list, new_parent_path) orelse return error.ParentNotFound;
    if (std.mem.eql(u8, new_parent.path, target.path)) return error.ReparentCycle;
    const target_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{target.path});
    defer allocator.free(target_prefix);
    if (std.mem.startsWith(u8, new_parent.path, target_prefix)) return error.ReparentCycle;

    const parent_for_sibling = new_parent.path;
    if (hasSiblingNameExcluding(&list, parent_for_sibling, target.name, target.path)) {
        return error.DuplicateNodeName;
    }

    const old_prefix = try nodePathPrefixFromViewport(allocator, scene_root.name, target.path);
    defer allocator.free(old_prefix);

    const new_parent_attr = try viewportPathToParentAttr(allocator, scene_root.name, new_parent.path);
    defer allocator.free(new_parent_attr);

    const section_index = try findNodeSectionIndex(allocator, doc, target.path);
    const section = &doc.sections.items[section_index];
    if (std.mem.eql(u8, scene_root.path, new_parent.path)) {
        try section.header.setStringField(allocator, "parent", ".");
    } else {
        try section.header.setStringField(allocator, "parent", new_parent_attr);
    }

    const new_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ new_parent.path, target.name });
    defer allocator.free(new_path);

    const new_prefix = try nodePathPrefixFromViewport(allocator, scene_root.name, new_path);
    defer allocator.free(new_prefix);

    if (old_prefix.len > 0 and !std.mem.eql(u8, old_prefix, new_prefix)) {
        const old_with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{old_prefix});
        defer allocator.free(old_with_slash);
        for (doc.sections.items) |*child_section| {
            if (!std.mem.eql(u8, child_section.header.name, "node")) continue;
            const parent_attr = child_section.header.getString("parent") orelse continue;
            if (std.mem.eql(u8, parent_attr, old_prefix)) {
                try child_section.header.setStringField(allocator, "parent", new_prefix);
                continue;
            }
            if (std.mem.startsWith(u8, parent_attr, old_with_slash)) {
                const suffix = parent_attr[old_with_slash.len..];
                const rewritten = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ new_prefix, suffix });
                defer allocator.free(rewritten);
                try child_section.header.setStringField(allocator, "parent", rewritten);
            }
        }
        try scene_connections.rewritePaths(allocator, doc, old_prefix, new_prefix);
    }

    try node_section_order.moveSubtreeAfterReparent(allocator, doc, section_index, new_parent.path);
}

pub fn findNodeSectionIndex(allocator: std.mem.Allocator, doc: *const document.Document, node_path: []const u8) Error!usize {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);
    const node = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;
    return node.section_index;
}

fn descUsize(_: void, a: usize, b: usize) bool {
    return a > b;
}

fn makeNodeHeader(allocator: std.mem.Allocator, name: []const u8, node_type: []const u8, parent_attr: ?[]const u8) Error!tag.Tag {
    var header = tag.Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
    try header.setStringField(allocator, "name", name);
    try header.setStringField(allocator, "type", node_type);
    if (parent_attr) |parent| {
        try header.setStringField(allocator, "parent", parent);
    }
    return header;
}

fn findSceneRoot(list: *const node_tree.NodeList) Error!?*const node_tree.NodeInfo {
    for (list.nodes) |*node| {
        if (node.parent.len == 0) return node;
    }
    return null;
}

fn parentViewportPath(allocator: std.mem.Allocator, path: []const u8) Error!?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/root/")) return error.InvalidNodePath;
    const last = std.mem.lastIndexOf(u8, path, "/") orelse return null;
    const parent = path[0..last];
    if (std.mem.eql(u8, parent, "/root")) return null;
    return try allocator.dupe(u8, parent);
}

/// Godot `parent` attribute path from scene root (e.g. `Player/Sprite`), empty for scene root.
pub fn nodePathPrefixFromViewport(allocator: std.mem.Allocator, scene_root_name: []const u8, viewport_path: []const u8) Error![]const u8 {
    const root_prefix = try std.fmt.allocPrint(allocator, "/root/{s}", .{scene_root_name});
    defer allocator.free(root_prefix);

    if (std.mem.eql(u8, viewport_path, root_prefix)) return try allocator.dupe(u8, "");

    const child_prefix = try std.fmt.allocPrint(allocator, "/root/{s}/", .{scene_root_name});
    defer allocator.free(child_prefix);
    if (!std.mem.startsWith(u8, viewport_path, child_prefix)) return error.InvalidNodePath;

    return try allocator.dupe(u8, viewport_path[child_prefix.len..]);
}

/// Viewport parent path → Godot `parent` attribute (`.` for scene root).
pub fn viewportPathToParentAttr(allocator: std.mem.Allocator, scene_root_name: []const u8, parent_viewport_path: []const u8) Error![]const u8 {
    const root_path = try std.fmt.allocPrint(allocator, "/root/{s}", .{scene_root_name});
    defer allocator.free(root_path);
    if (std.mem.eql(u8, parent_viewport_path, root_path)) return try allocator.dupe(u8, ".");

    const prefix = try std.fmt.allocPrint(allocator, "/root/{s}/", .{scene_root_name});
    defer allocator.free(prefix);
    if (!std.mem.startsWith(u8, parent_viewport_path, prefix)) return error.InvalidNodePath;
    return try allocator.dupe(u8, parent_viewport_path[prefix.len..]);
}

fn hasSiblingName(list: *const node_tree.NodeList, parent_viewport_path: []const u8, name: []const u8) bool {
    return hasSiblingNameExcluding(list, parent_viewport_path, name, "");
}

fn hasSiblingNameExcluding(
    list: *const node_tree.NodeList,
    parent_viewport_path: []const u8,
    name: []const u8,
    exclude_path: []const u8,
) bool {
    for (list.nodes) |*node| {
        if (exclude_path.len > 0 and std.mem.eql(u8, node.path, exclude_path)) continue;
        if (!std.mem.eql(u8, node.name, name)) continue;
        const node_parent = parentViewportPathConst(node.path, list) orelse continue;
        if (std.mem.eql(u8, node_parent, parent_viewport_path)) return true;
    }
    return false;
}

fn parentViewportPathConst(node_path: []const u8, list: *const node_tree.NodeList) ?[]const u8 {
    for (list.nodes) |*node| {
        if (!std.mem.eql(u8, node.path, node_path)) continue;
        if (node.parent.len == 0) return null;
        const last = std.mem.lastIndexOf(u8, node.path, "/") orelse return null;
        return node.path[0..last];
    }
    return null;
}

fn hasDescendantPath(list: *const node_tree.NodeList, node_path: []const u8) bool {
    const prefix = blk: {
        // stack buffer for prefix check
        var buf: [512]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, "{s}/", .{node_path}) catch return false;
        break :blk written;
    };
    for (list.nodes) |*node| {
        if (std.mem.startsWith(u8, node.path, prefix)) return true;
    }
    return false;
}

test "create new scene" {
    const allocator = std.testing.allocator;
    var doc = try createNewScene(allocator, "Main", "Node2D");
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.sections.items.len);
    try std.testing.expectEqualStrings("gd_scene", doc.sections.items[0].header.name);
    try std.testing.expectEqualStrings("Main", doc.sections.items[1].header.getString("name").?);
}

test "add remove rename reparent nodes" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var added = try addNode(allocator, &doc, "/root/Main", "Player", "CharacterBody2D");
    defer added.deinit(allocator);
    try std.testing.expectEqualStrings("/root/Main/Player", added.path);
    try std.testing.expectEqualStrings(".", added.parent_attr);

    var sprite = try addNode(allocator, &doc, "/root/Main/Player", "Sprite", "Sprite2D");
    defer sprite.deinit(allocator);
    try std.testing.expectEqualStrings("Player", sprite.parent_attr);

    const renamed = try renameNode(allocator, &doc, "/root/Main/Player", "Hero");
    defer allocator.free(renamed);
    try std.testing.expectEqualStrings("/root/Main/Hero", renamed);

    try reparentNode(allocator, &doc, "/root/Main/Hero/Sprite", "/root/Main");
    var list = try node_tree.collectNodes(allocator, &doc);
    defer list.deinit(allocator);
    const sprite_node = node_tree.findByPath(&list, "/root/Main/Sprite").?;
    try std.testing.expectEqualStrings(".", sprite_node.parent);
    try std.testing.expectEqualStrings(".", sprite_node.parent);

    try std.testing.expectEqual(@as(usize, 1), try removeNode(allocator, &doc, "/root/Main/Sprite", false));
    try std.testing.expectEqual(@as(usize, 1), try removeNode(allocator, &doc, "/root/Main/Hero", false));
}

test "reparent preserves parent-before-child section order" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="."]
        \\
        \\[node name="Enemy" type="CharacterBody2D" parent="."]
        \\
        \\[node name="HUD" type="CanvasLayer" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var playfield = try addNode(allocator, &doc, "/root/Main", "Playfield", "Node2D");
    defer playfield.deinit(allocator);

    try reparentNode(allocator, &doc, "/root/Main/Player", "/root/Main/Playfield");
    try reparentNode(allocator, &doc, "/root/Main/Enemy", "/root/Main/Playfield");

    const playfield_idx = document.findSectionIndexByNodeName(&doc, "Playfield").?;
    const player_idx = document.findSectionIndexByNodeName(&doc, "Player").?;
    const enemy_idx = document.findSectionIndexByNodeName(&doc, "Enemy").?;
    try std.testing.expect(playfield_idx < player_idx);
    try std.testing.expect(playfield_idx < enemy_idx);
}

test "viewport parent attr helpers" {
    const allocator = std.testing.allocator;
    const dot = try viewportPathToParentAttr(allocator, "Main", "/root/Main");
    defer allocator.free(dot);
    try std.testing.expectEqualStrings(".", dot);
    const player = try viewportPathToParentAttr(allocator, "Main", "/root/Main/Player");
    defer allocator.free(player);
    try std.testing.expectEqualStrings("Player", player);
    const empty = try nodePathPrefixFromViewport(allocator, "Main", "/root/Main");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const nested = try nodePathPrefixFromViewport(allocator, "Main", "/root/Main/Player/Sprite");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("Player/Sprite", nested);
}
