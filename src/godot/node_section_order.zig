//! Godot `.tscn` node section ordering: parents before children (PackedScene load order).
//!
//! Godot instantiates nodes in file order; a child's `parent` path must refer to a node
//! already instantiated (`packed_scene.cpp` — "parent path has vanished"). Editor save
//! emits depth-first order from `SceneState`.

const std = @import("std");
const document = @import("text_format/document.zig");
const node_tree = @import("node_tree.zig");
const id_validate = @import("id_validate.zig");

pub const Error = error{
    NoSceneRoot,
} || node_tree.Error || document.EditError;

/// Reorder `[node]` sections so every parent appears before its descendants.
/// Non-node sections keep relative placement: before the node block, between (rare), after.
pub fn sortNodeSections(allocator: std.mem.Allocator, doc: *document.Document) Error!void {
    const first_node = document.firstNodeSectionIndex(doc) orelse return;
    const last_node = document.lastNodeSectionIndex(doc).?;

    var node_indices: std.ArrayList(usize) = .empty;
    defer node_indices.deinit(allocator);
    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "node")) {
            try node_indices.append(allocator, index);
        }
    }
    if (node_indices.items.len < 2) return;

    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const sorted_indices = try topologicalNodeSectionOrder(allocator, &list);
    defer allocator.free(sorted_indices);

    var already_sorted = true;
    for (node_indices.items, 0..) |old_index, i| {
        if (old_index != sorted_indices[i]) {
            already_sorted = false;
            break;
        }
    }
    if (already_sorted) return;

    var prefix: std.ArrayList(usize) = .empty;
    defer prefix.deinit(allocator);
    var interleaved: std.ArrayList(usize) = .empty;
    defer interleaved.deinit(allocator);
    var suffix: std.ArrayList(usize) = .empty;
    defer suffix.deinit(allocator);

    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "node")) continue;
        if (index < first_node) {
            try prefix.append(allocator, index);
        } else if (index > last_node) {
            try suffix.append(allocator, index);
        } else {
            try interleaved.append(allocator, index);
        }
    }

    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.appendSlice(allocator, prefix.items);
    try order.appendSlice(allocator, sorted_indices);
    try order.appendSlice(allocator, interleaved.items);
    try order.appendSlice(allocator, suffix.items);

    try reorderSectionsByIndex(allocator, doc, order.items);
}

/// Index in `doc.sections` where a new child of `parent_viewport_path` should be inserted.
pub fn insertIndexForNewChild(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    parent_viewport_path: []const u8,
) Error!usize {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const parent = node_tree.findByPath(&list, parent_viewport_path) orelse return doc.sections.items.len;
    var insert_at = parent.section_index + 1;

    const parent_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{parent_viewport_path});
    defer allocator.free(parent_prefix);

    for (list.nodes) |*node| {
        if (node.section_index <= parent.section_index) continue;
        if (std.mem.eql(u8, node.path, parent_viewport_path)) continue;
        if (std.mem.startsWith(u8, node.path, parent_prefix)) {
            if (node.section_index + 1 > insert_at) insert_at = node.section_index + 1;
        }
    }

    return insert_at;
}

/// After reparenting, move `subtree_root_section_index` and all descendants to sit under `new_parent_path`.
pub fn moveSubtreeAfterReparent(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    subtree_root_section_index: usize,
    new_parent_viewport_path: []const u8,
) Error!void {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const root = findBySectionIndex(&list, subtree_root_section_index) orelse return;

    const subtree_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{root.path});
    defer allocator.free(subtree_prefix);

    var block: std.ArrayList(usize) = .empty;
    defer block.deinit(allocator);
    try block.append(allocator, root.section_index);
    for (list.nodes) |*node| {
        if (std.mem.startsWith(u8, node.path, subtree_prefix)) {
            try block.append(allocator, node.section_index);
        }
    }
    std.mem.sort(usize, block.items, {}, std.sort.asc(usize));

    var sections: std.ArrayList(document.Section) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }
    var shift: usize = 0;
    for (block.items) |index| {
        const removed = try document.removeSection(doc, index - shift);
        try sections.append(allocator, removed);
        shift += 1;
    }

    const insert_at = try insertIndexForNewChild(allocator, doc, new_parent_viewport_path);
    var offset: usize = 0;
    for (sections.items) |section| {
        try document.insertSection(doc, allocator, insert_at + offset, section);
        offset += 1;
    }
}

pub fn validateNodeParentOrder(
    report: *id_validate.Report,
    allocator: std.mem.Allocator,
    doc: *const document.Document,
) Error!void {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const scene_root = findSceneRoot(&list) orelse return;
    const root_path = scene_root.path;

    var declared = std.StringHashMap(void).init(allocator);
    defer {
        var it = declared.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        declared.deinit();
    }

    const gop_root = try declared.getOrPut(try allocator.dupe(u8, root_path));
    if (!gop_root.found_existing) {}

    // Visit nodes in file order (section_index).
    var ordered: std.ArrayList(*const node_tree.NodeInfo) = .empty;
    defer ordered.deinit(allocator);
    for (list.nodes) |*node| {
        try ordered.append(allocator, node);
    }
    std.mem.sort(*const node_tree.NodeInfo, ordered.items, {}, nodeSectionOrderLess);

    for (ordered.items) |node| {
        if (node.parent.len == 0) continue;

        const parent_path = try parentViewportPath(allocator, root_path, node.parent);
        defer allocator.free(parent_path);

        if (!declared.contains(parent_path)) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "node '{s}' parent '{s}' is declared later in the file (Godot instantiate: parent path vanished)",
                .{ node.name, node.parent },
            );
            defer allocator.free(msg);
            try report.add(allocator, .err, "node_parent_order", msg, node.section_line);
        }

        const path_copy = try allocator.dupe(u8, node.path);
        const gop = try declared.getOrPut(path_copy);
        if (gop.found_existing) allocator.free(path_copy);
    }
}

fn findBySectionIndex(list: *const node_tree.NodeList, section_index: usize) ?*const node_tree.NodeInfo {
    for (list.nodes) |*node| {
        if (node.section_index == section_index) return node;
    }
    return null;
}

fn nodeSectionOrderLess(_: void, a: *const node_tree.NodeInfo, b: *const node_tree.NodeInfo) bool {
    return a.section_index < b.section_index;
}

fn findSceneRoot(list: *const node_tree.NodeList) ?*const node_tree.NodeInfo {
    for (list.nodes) |*node| {
        if (node.parent.len == 0) return node;
    }
    return null;
}

fn parentViewportPath(allocator: std.mem.Allocator, root_path: []const u8, parent_attr: []const u8) ![]const u8 {
    const root_name = root_path["/root/".len..];
    if (std.mem.eql(u8, parent_attr, ".") or std.mem.eql(u8, parent_attr, root_name)) {
        return try allocator.dupe(u8, root_path);
    }
    return try std.fmt.allocPrint(allocator, "/root/{s}/{s}", .{ root_name, parent_attr });
}

fn topologicalNodeSectionOrder(allocator: std.mem.Allocator, list: *const node_tree.NodeList) Error![]usize {
    const scene_root = findSceneRoot(list) orelse return error.NoSceneRoot;

    var child_lists = std.StringHashMap(std.ArrayList(*const node_tree.NodeInfo)).init(allocator);
    defer {
        var map_it = child_lists.iterator();
        while (map_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        child_lists.deinit();
    }

    for (list.nodes) |*node| {
        if (node.parent.len == 0) continue;
        const parent_path = try parentViewportPath(allocator, scene_root.path, node.parent);
        const gop = try child_lists.getOrPut(parent_path);
        if (gop.found_existing) {
            allocator.free(parent_path);
        } else {
            gop.key_ptr.* = parent_path;
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, node);
    }

    var map_values = child_lists.valueIterator();
    while (map_values.next()) |child_list| {
        std.mem.sort(*const node_tree.NodeInfo, child_list.items, {}, nodeSectionOrderLess);
    }

    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);

    var stack: std.ArrayList([]const u8) = .empty;
    defer {
        for (stack.items) |path| allocator.free(path);
        stack.deinit(allocator);
    }

    try out.append(allocator, scene_root.section_index);
    if (child_lists.get(scene_root.path)) |root_children| {
        var i = root_children.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, try allocator.dupe(u8, root_children.items[i].path));
        }
    }

    while (stack.items.len > 0) {
        const path = stack.items[stack.items.len - 1];
        _ = stack.orderedRemove(stack.items.len - 1);
        defer allocator.free(path);

        const node = node_tree.findByPath(list, path) orelse continue;
        try out.append(allocator, node.section_index);

        if (child_lists.get(path)) |kids| {
            var i = kids.items.len;
            while (i > 0) {
                i -= 1;
                try stack.append(allocator, try allocator.dupe(u8, kids.items[i].path));
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn reorderSectionsByIndex(allocator: std.mem.Allocator, doc: *document.Document, order: []const usize) !void {
    var reordered: std.ArrayList(document.Section) = .empty;
    try reordered.ensureTotalCapacity(allocator, order.len);
    for (order) |idx| {
        try reordered.append(allocator, doc.sections.items[idx]);
    }

    for (doc.sections.items) |*section| {
        section.* = document.Section{
            .line = 0,
            .leading_blank_lines = 1,
            .header = .{ .name = "", .fields = .{} },
            .properties = .empty,
        };
    }
    doc.sections.deinit(allocator);
    doc.sections = reordered;
}

test "move subtree after reparent" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="."]
        \\
        \\[node name="Playfield" type="Node2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const player_idx = document.findSectionIndexByNodeName(&doc, "Player").?;
    const section = &doc.sections.items[player_idx];
    try section.header.setStringField(allocator, "parent", "Playfield");

    try moveSubtreeAfterReparent(allocator, &doc, player_idx, "/root/Main/Playfield");

    const playfield_idx = document.findSectionIndexByNodeName(&doc, "Playfield").?;
    const player_after = document.findSectionIndexByNodeName(&doc, "Player").?;
    try std.testing.expect(playfield_idx < player_after);
}

test "sort node sections parent before child" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="Playfield"]
        \\
        \\[node name="HUD" type="CanvasLayer" parent="."]
        \\
        \\[node name="Playfield" type="Node2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try sortNodeSections(allocator, &doc);

    const playfield_idx = document.findSectionIndexByNodeName(&doc, "Playfield").?;
    const player_idx = document.findSectionIndexByNodeName(&doc, "Player").?;
    try std.testing.expect(playfield_idx < player_idx);
}

test "validate detects child before parent" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="Playfield"]
        \\
        \\[node name="Playfield" type="Node2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var report = id_validate.Report.init(allocator);
    defer report.deinit(allocator);
    try validateNodeParentOrder(&report, allocator, &doc);
    try std.testing.expect(id_validate.hasErrors(&report));
    try std.testing.expect(std.mem.eql(u8, report.issues.items[0].kind, "node_parent_order"));
}
