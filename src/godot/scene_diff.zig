//! Compare node trees and node properties between two scene documents.

const std = @import("std");
const document = @import("text_format/document.zig");
const node_tree = @import("node_tree.zig");
const scene_connections = @import("scene_connections.zig");

pub const Error = error{OutOfMemory} || node_tree.Error || scene_connections.Error;

pub const DiffItem = struct {
    kind: []const u8,
    path: []const u8,
    type_a: ?[]const u8 = null,
    type_b: ?[]const u8 = null,
    /// The scene an instanced node instances, on each side. Such a node has
    /// no `type` in the file; its class is that scene's root.
    instance_path_a: ?[]const u8 = null,
    instance_path_b: ?[]const u8 = null,
    unique_id_a: ?i64 = null,
    unique_id_b: ?i64 = null,

    pub fn deinit(self: *const DiffItem, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
        if (self.type_a) |t| allocator.free(t);
        if (self.type_b) |t| allocator.free(t);
        if (self.instance_path_a) |t| allocator.free(t);
        if (self.instance_path_b) |t| allocator.free(t);
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

pub const ConnectionDiffItem = struct {
    kind: []const u8,
    from: []const u8,
    signal: []const u8,
    to: []const u8,
    method: []const u8,

    pub fn deinit(self: *const ConnectionDiffItem, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.from);
        allocator.free(self.signal);
        allocator.free(self.to);
        allocator.free(self.method);
    }
};

/// An `[ext_resource]` or `[sub_resource]` that differs. An ext_resource is
/// keyed by its path, since its local id is renumbered freely; a sub_resource
/// by its id, which Godot keeps stable across saves.
pub const ResourceDiffItem = struct {
    kind: []const u8,
    section: []const u8,
    key: []const u8,
    type_a: ?[]const u8 = null,
    type_b: ?[]const u8 = null,
    uid_a: ?[]const u8 = null,
    uid_b: ?[]const u8 = null,

    pub fn deinit(self: *const ResourceDiffItem, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.section);
        allocator.free(self.key);
        for ([_]?[]const u8{ self.type_a, self.type_b, self.uid_a, self.uid_b }) |field| if (field) |text| allocator.free(text);
    }
};

pub const DiffOptions = struct {
    include_properties: bool = false,
};

pub const DiffResult = struct {
    nodes: []DiffItem,
    properties: []PropertyDiffItem,
    connections: []ConnectionDiffItem = &.{},
    resources: []ResourceDiffItem = &.{},
    identical: bool,
    node_count_a: usize,
    node_count_b: usize,

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        for (self.nodes) |*item| item.deinit(allocator);
        allocator.free(self.nodes);
        for (self.properties) |*item| item.deinit(allocator);
        allocator.free(self.properties);
        for (self.connections) |*item| item.deinit(allocator);
        if (self.connections.len != 0) allocator.free(self.connections);
        for (self.resources) |*item| item.deinit(allocator);
        if (self.resources.len != 0) allocator.free(self.resources);
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
    var result = try diffNodeLists(allocator, doc_a, doc_b, &list_a, &list_b, options);
    errdefer result.deinit(allocator);
    result.connections = try diffConnections(allocator, doc_a, doc_b);
    if (result.connections.len != 0) result.identical = false;
    // Trial 32 found the ext_resource its HUD instance added through `scene
    // describe`, because the diff did not mention resources at all.
    var sub_properties: std.ArrayList(PropertyDiffItem) = .empty;
    defer sub_properties.deinit(allocator);
    errdefer for (sub_properties.items) |*item| item.deinit(allocator);
    result.resources = try diffResources(allocator, doc_a, doc_b, options, &sub_properties);
    if (sub_properties.items.len != 0) {
        const merged = try allocator.alloc(PropertyDiffItem, result.properties.len + sub_properties.items.len);
        @memcpy(merged[0..result.properties.len], result.properties);
        @memcpy(merged[result.properties.len..], sub_properties.items);
        allocator.free(result.properties);
        result.properties = merged;
        sub_properties.clearRetainingCapacity();
    }
    if (result.resources.len != 0 or result.properties.len != 0) result.identical = false;
    return result;
}

/// A connection is identified by everything Godot writes for it, so a change
/// to flags or binds shows as a remove plus an add.
fn connectionKey(allocator: std.mem.Allocator, info: *const scene_connections.ConnectionInfo) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}\x00{s}\x00{d}\x00{s}\x00{d}", .{
        info.from_path, info.signal, info.to_path, info.method, info.flags, info.binds orelse "", info.unbinds orelse 0,
    });
}

fn diffConnections(allocator: std.mem.Allocator, doc_a: *const document.Document, doc_b: *const document.Document) Error![]ConnectionDiffItem {
    var a = try scene_connections.collect(allocator, doc_a);
    defer a.deinit(allocator);
    var b = try scene_connections.collect(allocator, doc_b);
    defer b.deinit(allocator);

    var items: std.ArrayList(ConnectionDiffItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for ([_]struct { from: []scene_connections.ConnectionInfo, against: []scene_connections.ConnectionInfo, kind: []const u8 }{
        .{ .from = a.items, .against = b.items, .kind = "removed" },
        .{ .from = b.items, .against = a.items, .kind = "added" },
    }) |side| {
        for (side.from) |*info| {
            const key = try connectionKey(allocator, info);
            defer allocator.free(key);
            var found = false;
            for (side.against) |*other| {
                const other_key = try connectionKey(allocator, other);
                defer allocator.free(other_key);
                if (std.mem.eql(u8, key, other_key)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            try items.append(allocator, .{
                .kind = try allocator.dupe(u8, side.kind),
                .from = try allocator.dupe(u8, info.from_path),
                .signal = try allocator.dupe(u8, info.signal),
                .to = try allocator.dupe(u8, info.to_path),
                .method = try allocator.dupe(u8, info.method),
            });
        }
    }
    return try items.toOwnedSlice(allocator);
}

pub fn diffToObjectMap(allocator: std.mem.Allocator, diff: *const DiffResult) Error!std.json.ObjectMap {
    var nodes_json = std.json.Array.init(allocator);
    for (diff.nodes) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "kind", .{ .string = try allocator.dupe(u8, item.kind) });
        try row.put(allocator, "path", .{ .string = try allocator.dupe(u8, item.path) });
        // An instanced node has no type of its own in the file. PackedScene
        // is what `scene node list` reports for it; the command swaps in the
        // instanced scene's root class when it has a project root.
        if (item.type_a) |type_a| {
            const shown = if (type_a.len == 0 and item.instance_path_a != null) "PackedScene" else type_a;
            try row.put(allocator, "type_a", .{ .string = try allocator.dupe(u8, shown) });
        }
        if (item.type_b) |type_b| {
            const shown = if (type_b.len == 0 and item.instance_path_b != null) "PackedScene" else type_b;
            try row.put(allocator, "type_b", .{ .string = try allocator.dupe(u8, shown) });
        }
        if (item.instance_path_a) |instance| try row.put(allocator, "instance_path_a", .{ .string = try allocator.dupe(u8, instance) });
        if (item.instance_path_b) |instance| try row.put(allocator, "instance_path_b", .{ .string = try allocator.dupe(u8, instance) });
        if (item.unique_id_a) |id| try row.put(allocator, "unique_id_a", .{ .integer = id });
        if (item.unique_id_b) |id| try row.put(allocator, "unique_id_b", .{ .integer = id });
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

    var connections_json = std.json.Array.init(allocator);
    for (diff.connections) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "kind", .{ .string = try allocator.dupe(u8, item.kind) });
        try row.put(allocator, "from", .{ .string = try allocator.dupe(u8, item.from) });
        try row.put(allocator, "signal", .{ .string = try allocator.dupe(u8, item.signal) });
        try row.put(allocator, "to", .{ .string = try allocator.dupe(u8, item.to) });
        try row.put(allocator, "method", .{ .string = try allocator.dupe(u8, item.method) });
        try connections_json.append(.{ .object = row });
    }

    var resources_json = std.json.Array.init(allocator);
    for (diff.resources) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "kind", .{ .string = try allocator.dupe(u8, item.kind) });
        try row.put(allocator, "section", .{ .string = try allocator.dupe(u8, item.section) });
        const key_name = if (std.mem.eql(u8, item.section, "ext_resource")) "path" else "id";
        try row.put(allocator, key_name, .{ .string = try allocator.dupe(u8, item.key) });
        inline for (.{ .{ "type_a", "type_a" }, .{ "type_b", "type_b" }, .{ "uid_a", "uid_a" }, .{ "uid_b", "uid_b" } }) |field| {
            if (@field(item, field[0])) |text| try row.put(allocator, field[1], .{ .string = try allocator.dupe(u8, text) });
        }
        try resources_json.append(.{ .object = row });
    }
    const total_diffs = diff.nodes.len + diff.properties.len + diff.connections.len + diff.resources.len;

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "identical", .{ .bool = diff.identical });
    try data.put(allocator, "node_count_a", .{ .integer = @intCast(diff.node_count_a) });
    try data.put(allocator, "node_count_b", .{ .integer = @intCast(diff.node_count_b) });
    try data.put(allocator, "node_diff_count", .{ .integer = @intCast(diff.nodes.len) });
    try data.put(allocator, "property_diff_count", .{ .integer = @intCast(diff.properties.len) });
    try data.put(allocator, "diff_count", .{ .integer = @intCast(total_diffs) });
    try data.put(allocator, "connection_diff_count", .{ .integer = @intCast(diff.connections.len) });
    try data.put(allocator, "resource_diff_count", .{ .integer = @intCast(diff.resources.len) });
    try data.put(allocator, "nodes", .{ .array = nodes_json });
    try data.put(allocator, "properties", .{ .array = properties_json });
    try data.put(allocator, "connections", .{ .array = connections_json });
    try data.put(allocator, "resources", .{ .array = resources_json });
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
    var nodes_b: std.StringArrayHashMapUnmanaged(*const node_tree.NodeInfo) = .empty;
    defer nodes_b.deinit(allocator);
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
        try nodes_b.put(allocator, node.path, node);
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
                .instance_path_a = try dupeOptional(allocator, node.instance_path),
                .unique_id_a = node.unique_id,
            });
            continue;
        }
        // Godot tracks a node by its unique_id, so the same path with a new
        // id is a different node as far as the editor is concerned.
        const other = nodes_b.get(node.path).?;
        if (node.unique_id != null and other.unique_id != null and node.unique_id.? != other.unique_id.?) {
            try node_items.append(allocator, .{
                .kind = try allocator.dupe(u8, "unique_id_changed"),
                .path = try allocator.dupe(u8, node.path),
                .unique_id_a = node.unique_id,
                .unique_id_b = other.unique_id,
            });
        }
        if (!std.mem.eql(u8, node.node_type, type_b.?)) {
            try node_items.append(allocator, .{
                .kind = try allocator.dupe(u8, "type_changed"),
                .path = try allocator.dupe(u8, node.path),
                .type_a = try allocator.dupe(u8, node.node_type),
                .type_b = try allocator.dupe(u8, type_b.?),
                .instance_path_a = try dupeOptional(allocator, node.instance_path),
                .instance_path_b = try dupeOptional(allocator, nodes_b.get(node.path).?.instance_path),
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
                .instance_path_b = try dupeOptional(allocator, node.instance_path),
                .unique_id_b = node.unique_id,
            });
        }
    }

    var property_items: std.ArrayList(PropertyDiffItem) = .empty;
    errdefer {
        for (property_items.items) |*item| item.deinit(allocator);
        property_items.deinit(allocator);
    }

    // A node on one side only is diffed against nothing, so an added node
    // lists the properties it arrived with and a removed one those it took
    // with it. Trial 31 added a mesh with a transform and got no properties.
    if (options.include_properties) {
        for (list_a.nodes) |*node| {
            const section_a = &doc_a.sections.items[node.section_index];
            const section_b = if (index_b.get(node.path)) |index| &doc_b.sections.items[index] else null;
            try diffSectionProperties(allocator, node.path, section_a, section_b, &property_items);
        }
        for (list_b.nodes) |*node| {
            if (index_a.get(node.path) != null) continue;
            try diffSectionProperties(allocator, node.path, null, &doc_b.sections.items[node.section_index], &property_items);
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
    section_a: ?*const document.Section,
    section_b: ?*const document.Section,
    out: *std.ArrayList(PropertyDiffItem),
) Error!void {
    var props_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer props_a.deinit(allocator);
    var props_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer props_b.deinit(allocator);

    if (section_a) |section| for (section.properties.items) |prop| {
        const name = propertyName(prop.raw) orelse continue;
        const value = propertyValue(prop.raw);
        try props_a.put(allocator, name, value);
    };
    if (section_b) |section| for (section.properties.items) |prop| {
        const name = propertyName(prop.raw) orelse continue;
        const value = propertyValue(prop.raw);
        try props_b.put(allocator, name, value);
    };

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

fn diffResources(
    allocator: std.mem.Allocator,
    doc_a: *const document.Document,
    doc_b: *const document.Document,
    options: DiffOptions,
    sub_properties: *std.ArrayList(PropertyDiffItem),
) Error![]ResourceDiffItem {
    var items: std.ArrayList(ResourceDiffItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    inline for (.{ .{ "ext_resource", "path" }, .{ "sub_resource", "id" } }) |kind| {
        const section_name = kind[0];
        const key_field = kind[1];
        var in_a: std.StringArrayHashMapUnmanaged(*const document.Section) = .empty;
        defer in_a.deinit(allocator);
        var in_b: std.StringArrayHashMapUnmanaged(*const document.Section) = .empty;
        defer in_b.deinit(allocator);
        for (doc_a.sections.items) |*section| if (std.mem.eql(u8, section.header.name, section_name)) {
            if (section.header.getString(key_field)) |key| try in_a.put(allocator, key, section);
        };
        for (doc_b.sections.items) |*section| if (std.mem.eql(u8, section.header.name, section_name)) {
            if (section.header.getString(key_field)) |key| try in_b.put(allocator, key, section);
        };
        for (in_a.keys(), in_a.values()) |key, section_a| {
            const section_b = in_b.get(key);
            const type_a = section_a.header.getString("type");
            const uid_a = section_a.header.getString("uid");
            if (section_b == null) {
                try items.append(allocator, .{ .kind = try allocator.dupe(u8, "removed"), .section = try allocator.dupe(u8, section_name), .key = try allocator.dupe(u8, key), .type_a = try dupeOptional(allocator, type_a), .uid_a = try dupeOptional(allocator, uid_a) });
                continue;
            }
            const type_b = section_b.?.header.getString("type");
            const uid_b = section_b.?.header.getString("uid");
            if (!optionalEql(type_a, type_b) or !optionalEql(uid_a, uid_b)) {
                try items.append(allocator, .{ .kind = try allocator.dupe(u8, "changed"), .section = try allocator.dupe(u8, section_name), .key = try allocator.dupe(u8, key), .type_a = try dupeOptional(allocator, type_a), .type_b = try dupeOptional(allocator, type_b), .uid_a = try dupeOptional(allocator, uid_a), .uid_b = try dupeOptional(allocator, uid_b) });
            }
            if (options.include_properties and comptime std.mem.eql(u8, section_name, "sub_resource")) {
                const address = try std.fmt.allocPrint(allocator, "SubResource(\"{s}\")", .{key});
                defer allocator.free(address);
                try diffSectionProperties(allocator, address, section_a, section_b.?, sub_properties);
            }
        }
        for (in_b.keys(), in_b.values()) |key, section_b| {
            if (in_a.get(key) != null) continue;
            try items.append(allocator, .{ .kind = try allocator.dupe(u8, "added"), .section = try allocator.dupe(u8, section_name), .key = try allocator.dupe(u8, key), .type_b = try dupeOptional(allocator, section_b.header.getString("type")), .uid_b = try dupeOptional(allocator, section_b.header.getString("uid")) });
        }
    }
    return items.toOwnedSlice(allocator);
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) Error!?[]const u8 {
    return if (text) |value| try allocator.dupe(u8, value) else null;
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

test "an added node lists its properties, and an instanced one names its scene" {
    // Trial 31 added a mesh with a transform and an instanced HUD: the diff
    // reported no properties and an empty type.
    const allocator = std.testing.allocator;
    const before =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node3D"]
        \\
    ;
    const after =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://ui/hud.tscn" id="1_hud"]
        \\
        \\[node name="Main" type="Node3D"]
        \\
        \\[node name="HUD" parent="." instance=ExtResource("1_hud")]
        \\
        \\[node name="Boulder" type="MeshInstance3D" parent="."]
        \\transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 6, 0, 0)
        \\
    ;
    var doc_a = try document.parseBytes(allocator, before);
    defer doc_a.deinit(allocator);
    var doc_b = try document.parseBytes(allocator, after);
    defer doc_b.deinit(allocator);

    var diff = try diffDocuments(allocator, &doc_a, &doc_b, .{ .include_properties = true });
    defer diff.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.properties.len);
    try std.testing.expectEqualStrings("property_added", diff.properties[0].kind);
    try std.testing.expectEqualStrings("transform", diff.properties[0].property);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const map = try diffToObjectMap(arena_state.allocator(), &diff);
    const hud = map.get("nodes").?.array.items[0].object;
    try std.testing.expectEqualStrings("PackedScene", hud.get("type_b").?.string);
    try std.testing.expectEqualStrings("res://ui/hud.tscn", hud.get("instance_path_b").?.string);

    // The mirror: removing them lists what went with them.
    var reverse = try diffDocuments(allocator, &doc_b, &doc_a, .{ .include_properties = true });
    defer reverse.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), reverse.properties.len);
    try std.testing.expectEqualStrings("property_removed", reverse.properties[0].kind);
}

test "resources are diffed: ext_resources by path, sub_resources by id" {
    // Trial 32 found an added ext_resource through `scene describe`, because
    // the diff reported none. An ext_resource's local id is renumbered freely,
    // so only its path identifies it.
    const allocator = std.testing.allocator;
    const before =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://a.gd" id="1_a"]
        \\[ext_resource type="Texture2D" path="res://icon.svg" id="2_icon"]
        \\
        \\[sub_resource type="BoxShape3D" id="BoxShape3D_1"]
        \\
        \\[node name="Main" type="Node3D" unique_id=10]
        \\
    ;
    const after =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Texture2D" path="res://icon.svg" id="1_renumbered"]
        \\[ext_resource type="PackedScene" path="res://hud.tscn" id="2_hud"]
        \\
        \\[sub_resource type="BoxShape3D" id="BoxShape3D_1"]
        \\size = Vector3(4, 1, 4)
        \\
        \\[node name="Main" type="Node3D" unique_id=11]
        \\
    ;
    var doc_a = try document.parseBytes(allocator, before);
    defer doc_a.deinit(allocator);
    var doc_b = try document.parseBytes(allocator, after);
    defer doc_b.deinit(allocator);
    var diff = try diffDocuments(allocator, &doc_a, &doc_b, .{ .include_properties = true });
    defer diff.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), diff.resources.len);
    try std.testing.expectEqualStrings("removed", diff.resources[0].kind);
    try std.testing.expectEqualStrings("res://a.gd", diff.resources[0].key);
    try std.testing.expectEqualStrings("added", diff.resources[1].kind);
    try std.testing.expectEqualStrings("res://hud.tscn", diff.resources[1].key);
    try std.testing.expectEqual(@as(usize, 1), diff.properties.len);
    try std.testing.expectEqualStrings("SubResource(\"BoxShape3D_1\")", diff.properties[0].path);
    try std.testing.expectEqual(@as(usize, 1), diff.nodes.len);
    try std.testing.expectEqualStrings("unique_id_changed", diff.nodes[0].kind);
    try std.testing.expect(!diff.identical);
}
