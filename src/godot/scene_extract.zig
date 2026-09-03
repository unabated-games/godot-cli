//! Move a subtree out of a scene into its own file and instance it back,
//! the editor's "Save Branch as Scene". Trial 17 rebuilt a HUD by hand from
//! inspected JSON, transcribing 23 properties, because nothing did this.
//!
//! The node and its descendants move with their properties and unique ids.
//! Resources they reference are copied into the new scene and pruned from the
//! source when nothing else uses them. Connections and editable-children
//! sections wholly inside the subtree move and are rewritten relative to the
//! new root; a connection that crosses the boundary is dropped and reported,
//! since the parent scene must connect to the instance instead.

const std = @import("std");
const document = @import("text_format/document.zig");
const tag = @import("text_format/tag.zig");
const node_tree = @import("node_tree.zig");

pub const Error = error{
    OutOfMemory,
    NodeNotFound,
    CannotExtractRoot,
    InvalidNodePath,
};

pub const Result = struct {
    /// The new document, owned by the caller.
    new_doc: document.Document,
    /// The extracted node's name, which the instance keeps.
    name: []const u8,
    /// Viewport path of the extracted node's parent in the source scene.
    parent_path: []const u8,
    moved_nodes: usize,
    moved_ext: usize,
    moved_sub: usize,
    moved_connections: usize,
    /// Human-readable descriptions of connections that crossed the boundary.
    dropped_connections: []const []const u8,
};

/// Take `node_path` and everything under it out of `doc` into a new document.
/// The caller adds the instance to `doc` (so id seeding stays in one place)
/// and writes both files.
pub fn extractSubtree(allocator: std.mem.Allocator, doc: *document.Document, node_path: []const u8) Error!Result {
    var list = node_tree.collectNodes(allocator, doc) catch return error.OutOfMemory;
    defer list.deinit(allocator);

    const target = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;
    if (target.parent.len == 0) return error.CannotExtractRoot;

    // Attribute-style path of the target relative to the scene root: the
    // form `parent=` and connection `from=`/`to=` use.
    const root_prefix_len = blk: {
        const after_root = std.mem.indexOfScalarPos(u8, node_path, "/root/".len, '/') orelse return error.InvalidNodePath;
        break :blk after_root + 1;
    };
    const target_rel = node_path[root_prefix_len..];
    const target_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{target_rel});
    defer allocator.free(target_prefix);
    const viewport_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{node_path});
    defer allocator.free(viewport_prefix);

    // Subtree node sections, in file order.
    var node_indices: std.ArrayList(usize) = .empty;
    defer node_indices.deinit(allocator);
    for (list.nodes) |*node| {
        if (node.section_index == target.section_index or std.mem.startsWith(u8, node.path, viewport_prefix)) {
            try node_indices.append(allocator, node.section_index);
        }
    }
    std.mem.sort(usize, node_indices.items, {}, std.sort.asc(usize));

    // Resource ids the subtree references, in properties and instance= attrs.
    var ext_ids: std.StringArrayHashMapUnmanaged(void) = .{};
    defer {
        for (ext_ids.keys()) |key| allocator.free(key);
        ext_ids.deinit(allocator);
    }
    var sub_ids: std.StringArrayHashMapUnmanaged(void) = .{};
    defer {
        for (sub_ids.keys()) |key| allocator.free(key);
        sub_ids.deinit(allocator);
    }
    for (node_indices.items) |index| {
        const section = doc.sections.items[index];
        if (section.header.getRaw("instance")) |raw| try collectIds(allocator, raw, &ext_ids, &sub_ids);
        for (section.properties.items) |prop| try collectIds(allocator, prop.raw, &ext_ids, &sub_ids);
    }
    // Sub-resources can reference other resources in turn.
    var grew = true;
    while (grew) {
        grew = false;
        for (doc.sections.items) |section| {
            if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
            const id = section.header.getString("id") orelse continue;
            if (!sub_ids.contains(id)) continue;
            const before = ext_ids.count() + sub_ids.count();
            for (section.properties.items) |prop| try collectIds(allocator, prop.raw, &ext_ids, &sub_ids);
            if (ext_ids.count() + sub_ids.count() != before) grew = true;
        }
    }

    var new_doc = document.Document.init(allocator);
    errdefer new_doc.deinit(allocator);

    var header = tag.Tag{ .name = try allocator.dupe(u8, "gd_scene"), .fields = .{} };
    try header.setIntegerField(allocator, "format", 3);
    try new_doc.sections.append(allocator, .{ .line = 0, .leading_blank_lines = 0, .header = header, .properties = .empty });

    var moved_ext: usize = 0;
    var moved_sub: usize = 0;
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "ext_resource")) {
            const id = section.header.getString("id") orelse continue;
            if (!ext_ids.contains(id)) continue;
            try new_doc.sections.append(allocator, try cloneSection(allocator, section));
            moved_ext += 1;
        }
    }
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "sub_resource")) {
            const id = section.header.getString("id") orelse continue;
            if (!sub_ids.contains(id)) continue;
            try new_doc.sections.append(allocator, try cloneSection(allocator, section));
            moved_sub += 1;
        }
    }

    // Nodes: the target becomes the root (no parent attribute); descendants
    // get their parent rewritten relative to it.
    for (node_indices.items) |index| {
        var cloned = try cloneSection(allocator, doc.sections.items[index]);
        if (index == target.section_index) {
            cloned.header.removeField(allocator, "parent");
        } else if (cloned.header.getString("parent")) |parent_attr| {
            const rewritten = try rewriteRelative(allocator, parent_attr, target_rel, target_prefix);
            defer allocator.free(rewritten);
            try cloned.header.setStringField(allocator, "parent", rewritten);
        }
        cloned.leading_blank_lines = 1;
        try new_doc.sections.append(allocator, cloned);
    }

    // Connections and editable-children sections.
    var moved_connections: usize = 0;
    var dropped: std.ArrayList([]const u8) = .empty;
    errdefer dropped.deinit(allocator);
    var remove_indices: std.ArrayList(usize) = .empty;
    defer remove_indices.deinit(allocator);
    try remove_indices.appendSlice(allocator, node_indices.items);

    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "connection")) {
            const from = section.header.getString("from") orelse continue;
            const to = section.header.getString("to") orelse continue;
            const from_in = inSubtree(from, target_rel, target_prefix);
            const to_in = inSubtree(to, target_rel, target_prefix);
            if (from_in and to_in) {
                var cloned = try cloneSection(allocator, section);
                const new_from = try rewriteRelative(allocator, from, target_rel, target_prefix);
                defer allocator.free(new_from);
                const new_to = try rewriteRelative(allocator, to, target_rel, target_prefix);
                defer allocator.free(new_to);
                try cloned.header.setStringField(allocator, "from", new_from);
                try cloned.header.setStringField(allocator, "to", new_to);
                try new_doc.sections.append(allocator, cloned);
                try remove_indices.append(allocator, index);
                moved_connections += 1;
            } else if (from_in or to_in) {
                const signal = section.header.getString("signal") orelse "";
                const method = section.header.getString("method") orelse "";
                try dropped.append(allocator, try std.fmt.allocPrint(allocator, "signal {s} from {s} to {s} method {s}", .{ signal, from, to, method }));
                try remove_indices.append(allocator, index);
            }
        } else if (std.mem.eql(u8, section.header.name, "editable")) {
            const path = section.header.getString("path") orelse continue;
            if (!inSubtree(path, target_rel, target_prefix)) continue;
            var cloned = try cloneSection(allocator, section);
            const new_path = try rewriteRelative(allocator, path, target_rel, target_prefix);
            defer allocator.free(new_path);
            try cloned.header.setStringField(allocator, "path", new_path);
            try new_doc.sections.append(allocator, cloned);
            try remove_indices.append(allocator, index);
        }
    }

    // Remove moved sections from the source, highest index first.
    std.mem.sort(usize, remove_indices.items, {}, std.sort.desc(usize));
    for (remove_indices.items) |index| {
        var removed = doc.sections.orderedRemove(index);
        removed.deinit(allocator);
    }

    // Resources nothing in the source uses any more go with the subtree.
    try pruneUnreferenced(allocator, doc, "ext_resource", "ExtResource(\"", ext_ids.keys());
    try pruneUnreferenced(allocator, doc, "sub_resource", "SubResource(\"", sub_ids.keys());

    const last_slash = std.mem.lastIndexOfScalar(u8, node_path, '/') orelse return error.InvalidNodePath;
    return .{
        .new_doc = new_doc,
        .name = try allocator.dupe(u8, target.name),
        .parent_path = try allocator.dupe(u8, node_path[0..last_slash]),
        .moved_nodes = node_indices.items.len,
        .moved_ext = moved_ext,
        .moved_sub = moved_sub,
        .moved_connections = moved_connections,
        .dropped_connections = try dropped.toOwnedSlice(allocator),
    };
}

/// Drop resource sections among `ids` that no remaining section refers to.
fn pruneUnreferenced(allocator: std.mem.Allocator, doc: *document.Document, section_name: []const u8, marker: []const u8, ids: []const []const u8) Error!void {
    for (ids) |id| {
        const needle = try std.fmt.allocPrint(allocator, "{s}{s}\")", .{ marker, id });
        defer allocator.free(needle);
        var referenced = false;
        var own_index: ?usize = null;
        for (doc.sections.items, 0..) |section, index| {
            if (std.mem.eql(u8, section.header.name, section_name)) {
                if (section.header.getString("id")) |existing| if (std.mem.eql(u8, existing, id)) {
                    own_index = index;
                    continue;
                };
            }
            if (section.header.getRaw("instance")) |raw| if (std.mem.indexOf(u8, raw, needle) != null) {
                referenced = true;
            };
            for (section.properties.items) |prop| if (std.mem.indexOf(u8, prop.raw, needle) != null) {
                referenced = true;
            };
        }
        if (!referenced) if (own_index) |index| {
            var removed = doc.sections.orderedRemove(index);
            removed.deinit(allocator);
        };
    }
}

fn inSubtree(attr_path: []const u8, target_rel: []const u8, target_prefix: []const u8) bool {
    return std.mem.eql(u8, attr_path, target_rel) or std.mem.startsWith(u8, attr_path, target_prefix);
}

/// `HUD` becomes `.`, `HUD/Box` becomes `Box`.
fn rewriteRelative(allocator: std.mem.Allocator, attr_path: []const u8, target_rel: []const u8, target_prefix: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, attr_path, target_rel)) return allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, attr_path, target_prefix)) return allocator.dupe(u8, attr_path[target_prefix.len..]);
    return allocator.dupe(u8, attr_path);
}

fn collectIds(
    allocator: std.mem.Allocator,
    text: []const u8,
    ext_ids: *std.StringArrayHashMapUnmanaged(void),
    sub_ids: *std.StringArrayHashMapUnmanaged(void),
) Error!void {
    try collectRefs(allocator, text, "ExtResource(\"", ext_ids);
    try collectRefs(allocator, text, "SubResource(\"", sub_ids);
}

fn collectRefs(allocator: std.mem.Allocator, text: []const u8, marker: []const u8, out: *std.StringArrayHashMapUnmanaged(void)) Error!void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, marker)) |start| {
        const id_start = start + marker.len;
        const id_end = std.mem.indexOfScalarPos(u8, text, id_start, '"') orelse return;
        // Owned copies: the sections these ids came from are freed before
        // the source is pruned.
        if (!out.contains(text[id_start..id_end])) try out.put(allocator, try allocator.dupe(u8, text[id_start..id_end]), {});
        search = id_end;
    }
}

fn cloneValue(allocator: std.mem.Allocator, value: tag.Value) Error!tag.Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .raw => |s| .{ .raw = try allocator.dupe(u8, s) },
        else => value,
    };
}

fn cloneSection(allocator: std.mem.Allocator, section: document.Section) Error!document.Section {
    var header = tag.Tag{ .name = try allocator.dupe(u8, section.header.name), .fields = .{} };
    errdefer header.deinit(allocator);
    var it = section.header.fields.iterator();
    while (it.next()) |entry| {
        try header.fields.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
    }
    var properties: std.ArrayList(document.PropertyLine) = .empty;
    errdefer properties.deinit(allocator);
    for (section.properties.items) |prop| {
        var copy = prop;
        copy.raw = try allocator.dupe(u8, prop.raw);
        try properties.append(allocator, copy);
    }
    return .{ .line = section.line, .leading_blank_lines = section.leading_blank_lines, .header = header, .properties = properties };
}

test "a subtree moves out with its resources and inner connections" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=3 format=3]
        \\
        \\[ext_resource type="Script" path="res://hud.gd" id="1_hud"]
        \\
        \\[ext_resource type="Texture2D" path="res://icon.svg" id="2_icon"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="Sprite2D" parent="."]
        \\texture = ExtResource("2_icon")
        \\
        \\[node name="HUD" type="CanvasLayer" parent="."]
        \\script = ExtResource("1_hud")
        \\
        \\[node name="Label" type="Label" parent="HUD"]
        \\text = "Health"
        \\
        \\[node name="Button" type="Button" parent="HUD"]
        \\
        \\[connection signal="pressed" from="HUD/Button" to="HUD" method="_on_pressed"]
        \\
        \\[connection signal="pressed" from="HUD/Button" to="." method="_on_main"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var result = try extractSubtree(allocator, &doc, "/root/Main/HUD");
    defer result.new_doc.deinit(allocator);
    defer allocator.free(result.name);
    defer allocator.free(result.parent_path);
    defer {
        for (result.dropped_connections) |d| allocator.free(d);
        allocator.free(result.dropped_connections);
    }

    try std.testing.expectEqual(@as(usize, 3), result.moved_nodes);
    try std.testing.expectEqual(@as(usize, 1), result.moved_ext);
    try std.testing.expectEqual(@as(usize, 1), result.moved_connections);
    try std.testing.expectEqual(@as(usize, 1), result.dropped_connections.len);
    try std.testing.expectEqualStrings("HUD", result.name);
    try std.testing.expectEqualStrings("/root/Main", result.parent_path);

    // New scene: root has no parent, children hang off ".", connection rewritten.
    const new_root = result.new_doc.sections.items[2];
    try std.testing.expectEqualStrings("HUD", new_root.header.getString("name").?);
    try std.testing.expect(new_root.header.getString("parent") == null);
    try std.testing.expectEqualStrings(".", result.new_doc.sections.items[3].header.getString("parent").?);
    const conn = result.new_doc.sections.items[result.new_doc.sections.items.len - 1];
    try std.testing.expectEqualStrings("Button", conn.header.getString("from").?);
    try std.testing.expectEqualStrings(".", conn.header.getString("to").?);

    // Source: HUD gone, the icon reference stays, the hud script is pruned.
    var kept_hud_script = false;
    var kept_icon = false;
    for (doc.sections.items) |section| {
        if (section.header.getString("name")) |n| try std.testing.expect(!std.mem.eql(u8, n, "HUD"));
        if (section.header.getString("id")) |id| {
            if (std.mem.eql(u8, id, "1_hud")) kept_hud_script = true;
            if (std.mem.eql(u8, id, "2_icon")) kept_icon = true;
        }
    }
    try std.testing.expect(!kept_hud_script);
    try std.testing.expect(kept_icon);
}
