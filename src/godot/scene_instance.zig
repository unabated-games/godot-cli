//! Add instanced PackedScene nodes to `.tscn` documents.

const std = @import("std");
const document = @import("text_format/document.zig");
const tag = @import("text_format/tag.zig");
const node_tree = @import("node_tree.zig");
const scene_edit = @import("scene_edit.zig");
const scene_resources = @import("scene_resources.zig");
const node_section_order = @import("node_section_order.zig");
const project_config = @import("project_config.zig");

pub const Error = error{
    OutOfMemory,
    NoSceneRoot,
    ParentNotFound,
    DuplicateNodeName,
    InvalidNodePath,
    NodeNotFound,
    AmbiguousNodeName,
    NotAnInstance,
    MissingChildType,
} || scene_resources.Error || document.EditError || node_tree.Error || scene_edit.Error;

pub const AddInstanceResult = struct {
    section_index: usize,
    path: []const u8,
    parent_attr: []const u8,
    ext_resource_id: []const u8,
    scene_path: []const u8,
    editable: bool,

    pub fn deinit(self: *const AddInstanceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.parent_attr);
        allocator.free(self.ext_resource_id);
        allocator.free(self.scene_path);
    }
};

pub fn addPackedSceneInstance(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    seed_path: []const u8,
    parent_path: []const u8,
    node_name: []const u8,
    scene_res_path: []const u8,
    scene_uid: ?[]const u8,
    editable: bool,
) Error!AddInstanceResult {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    const parent = node_tree.findByPath(&list, parent_path) orelse return error.ParentNotFound;
    if (hasSiblingName(&list, parent_path, node_name)) return error.DuplicateNodeName;

    const parent_attr = try scene_edit.viewportPathToParentAttr(allocator, scene_root.name, parent.path);
    errdefer allocator.free(parent_attr);

    var ext = try scene_resources.getOrAddExtResource(
        allocator,
        doc,
        seed_path,
        "PackedScene",
        scene_res_path,
        scene_uid,
    );
    errdefer ext.deinit(allocator);

    const ext_id = try allocator.dupe(u8, ext.id);
    errdefer allocator.free(ext_id);
    ext.deinit(allocator);

    const instance_ref = try std.fmt.allocPrint(allocator, "ExtResource(\"{s}\")", .{ext_id});
    errdefer allocator.free(instance_ref);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "name", node_name);
    try header.setStringField(allocator, "parent", parent_attr);
    try header.setStringField(allocator, "instance", instance_ref);
    allocator.free(instance_ref);

    const insert_at = try node_section_order.insertIndexForNewChild(allocator, doc, parent.path);
    try document.insertSection(doc, allocator, insert_at, .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });
    const section_index = insert_at;

    const new_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent.path, node_name });
    errdefer allocator.free(new_path);

    if (editable) {
        const editable_path = try scene_edit.nodePathPrefixFromViewport(allocator, scene_root.name, new_path);
        defer allocator.free(editable_path);
        try addEditableInstanceSection(allocator, doc, editable_path);
    }

    return .{
        .section_index = section_index,
        .path = new_path,
        .parent_attr = parent_attr,
        .ext_resource_id = ext_id,
        .scene_path = try allocator.dupe(u8, scene_res_path),
        .editable = editable,
    };
}

pub fn readSceneUidFromResPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    scene_res_path: []const u8,
) Error!?[]const u8 {
    const fs_path = try project_config.resPathToFilesystem(allocator, project_root, scene_res_path) orelse return null;
    defer allocator.free(fs_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, fs_path, allocator, .unlimited) catch return null;
    defer allocator.free(bytes);

    var parsed = document.parseBytes(allocator, bytes) catch return null;
    defer parsed.deinit(allocator);
    if (parsed.sections.items.len == 0) return null;
    const header = &parsed.sections.items[0].header;
    // Scenes and resources both carry their uid in the first header.
    if (!std.mem.eql(u8, header.name, "gd_scene") and !std.mem.eql(u8, header.name, "gd_resource")) return null;
    if (header.getString("uid")) |uid_text| return try allocator.dupe(u8, uid_text);
    return null;
}

pub fn ensureEditableInstance(allocator: std.mem.Allocator, doc: *document.Document, instance_path: []const u8) Error!void {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    const instance = node_tree.findByPath(&list, instance_path) orelse return error.NodeNotFound;
    const section = doc.sections.items[instance.section_index];
    if (section.header.getString("instance") == null) return error.NotAnInstance;

    const editable_path = try scene_edit.nodePathPrefixFromViewport(allocator, scene_root.name, instance_path);
    defer allocator.free(editable_path);

    if (hasEditableSection(doc, editable_path)) return;
    try addEditableInstanceSection(allocator, doc, editable_path);
}

pub fn setInstanceProperty(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    instance_path: []const u8,
    property: []const u8,
    value: []const u8,
) Error!void {
    const section_index = try scene_edit.findNodeSectionIndex(allocator, doc, instance_path);
    const section = doc.sections.items[section_index];
    if (section.header.getString("instance") == null) return error.NotAnInstance;
    try scene_edit.setNodeProperty(allocator, doc, instance_path, property, value);
}

pub fn setInstanceChildOverride(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    instance_path: []const u8,
    child_name: []const u8,
    child_type: ?[]const u8,
    property: []const u8,
    value: []const u8,
    ensure_editable: bool,
) Error![]const u8 {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const scene_root = try findSceneRoot(&list) orelse return error.NoSceneRoot;
    const instance = node_tree.findByPath(&list, instance_path) orelse return error.NodeNotFound;
    const instance_section = doc.sections.items[instance.section_index];
    if (instance_section.header.getString("instance") == null) return error.NotAnInstance;

    if (ensure_editable) {
        try ensureEditableInstance(allocator, doc, instance_path);
    }

    const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ instance_path, child_name });
    errdefer allocator.free(child_path);

    const child_node = node_tree.findByPath(&list, child_path);
    if (child_node == null) {
        const node_type = child_type orelse return error.MissingChildType;
        const parent_attr = try scene_edit.nodePathPrefixFromViewport(allocator, scene_root.name, instance_path);
        defer allocator.free(parent_attr);

        var header = tag.Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
        errdefer header.deinit(allocator);
        try header.setStringField(allocator, "name", child_name);
        try header.setStringField(allocator, "parent", parent_attr);
        try header.setStringField(allocator, "type", node_type);

        _ = try document.appendSection(doc, allocator, .{
            .line = 0,
            .leading_blank_lines = 1,
            .header = header,
            .properties = .empty,
        });
    }

    try scene_edit.setNodeProperty(allocator, doc, child_path, property, value);
    return child_path;
}

fn hasEditableSection(doc: *const document.Document, editable_path: []const u8) bool {
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "editable")) continue;
        if (section.header.getString("path")) |path| {
            if (std.mem.eql(u8, path, editable_path)) return true;
        }
    }
    return false;
}

fn addEditableInstanceSection(allocator: std.mem.Allocator, doc: *document.Document, node_path: []const u8) Error!void {
    var header = tag.Tag{ .name = try allocator.dupe(u8, "editable"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "path", node_path);

    _ = try document.appendSection(doc, allocator, .{
        .line = 0,
        .leading_blank_lines = 1,
        .header = header,
        .properties = .empty,
    });
}

fn findSceneRoot(list: *const node_tree.NodeList) Error!?*const node_tree.NodeInfo {
    for (list.nodes) |*node| {
        if (node.parent.len == 0) return node;
    }
    return null;
}

fn hasSiblingName(list: *const node_tree.NodeList, parent_viewport_path: []const u8, name: []const u8) bool {
    for (list.nodes) |*node| {
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

test "add packed scene instance" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var added = try addPackedSceneInstance(
        allocator,
        &doc,
        "res://main.tscn",
        "/root/Main",
        "MyButton",
        "res://ui/button/button.tscn",
        "uid://byhqeak2spha2",
        false,
    );
    defer added.deinit(allocator);

    try std.testing.expectEqualStrings("/root/Main/MyButton", added.path);
    try std.testing.expectEqualStrings(".", added.parent_attr);
    try std.testing.expectEqualStrings("res://ui/button/button.tscn", added.scene_path);
    try std.testing.expect(std.mem.startsWith(u8, added.ext_resource_id, "1_"));

    const ext_section = &doc.sections.items[1];
    try std.testing.expectEqualStrings("ext_resource", ext_section.header.name);
    try std.testing.expectEqualStrings("PackedScene", ext_section.header.getString("type").?);
    try std.testing.expectEqualStrings("uid://byhqeak2spha2", ext_section.header.getString("uid").?);

    const node_section = &doc.sections.items[3];
    try std.testing.expectEqualStrings("MyButton", node_section.header.getString("name").?);
    try std.testing.expectEqualStrings("ExtResource(\"", node_section.header.getString("instance").?[0..13]);
    try std.testing.expect(node_section.header.getString("type") == null);
}

test "reuse existing packed scene ext resource" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://ui/button/button.tscn" id="1_existing"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var added = try addPackedSceneInstance(
        allocator,
        &doc,
        "res://main.tscn",
        "/root/Main",
        "ButtonA",
        "res://ui/button/button.tscn",
        null,
        false,
    );
    defer added.deinit(allocator);

    try std.testing.expectEqualStrings("1_existing", added.ext_resource_id);
    try std.testing.expectEqual(@as(usize, 4), doc.sections.items.len);
}

test "instance child override adds editable section and property" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://ui/button/button.tscn" id="1_btn"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="MyButton" parent="." instance=ExtResource("1_btn")]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const child_path = try setInstanceChildOverride(
        allocator,
        &doc,
        "/root/Main/MyButton",
        "Label",
        "Label",
        "text",
        "\"Start\"",
        true,
    );
    defer allocator.free(child_path);

    try std.testing.expectEqualStrings("/root/Main/MyButton/Label", child_path);

    var has_editable = false;
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "editable")) has_editable = true;
    }
    try std.testing.expect(has_editable);
}

test "editable instance adds editable section" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var added = try addPackedSceneInstance(
        allocator,
        &doc,
        "res://main.tscn",
        "/root/Main",
        "MyButton",
        "res://ui/button/button.tscn",
        null,
        true,
    );
    defer added.deinit(allocator);

    const editable_section = &doc.sections.items[4];
    try std.testing.expectEqualStrings("editable", editable_section.header.name);
    try std.testing.expectEqualStrings("MyButton", editable_section.header.getString("path").?);
}
