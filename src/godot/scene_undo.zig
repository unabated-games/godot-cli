//! Scene snapshots and undo-patch recording for reversible edits.

const std = @import("std");
const document = @import("text_format/document.zig");
const node_tree = @import("node_tree.zig");
const scene_edit = @import("scene_edit.zig");
const scene_resources = @import("scene_resources.zig");
const scene_connections = @import("scene_connections.zig");
const io_util = @import("../io_util.zig");

pub const Error = error{
    OutOfMemory,
    Io,
    NodeNotFound,
    NoSceneRoot,
    InvalidNodePath,
    AmbiguousNodeName,
} || document.ParseError || node_tree.Error || scene_edit.Error;

pub const UndoRecorder = struct {
    arena: std.heap.ArenaAllocator,
    ops: std.ArrayList(std.json.Value),

    pub fn init(parent_allocator: std.mem.Allocator) UndoRecorder {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .ops = .empty,
        };
    }

    pub fn deinit(self: *UndoRecorder) void {
        self.ops.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn allocator(self: *UndoRecorder) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn prepend(self: *UndoRecorder, op: std.json.Value) Error!void {
        try self.ops.insert(self.allocator(), 0, op);
    }

    pub fn prependMany(self: *UndoRecorder, captured: []const std.json.Value) Error!void {
        var i = captured.len;
        while (i > 0) {
            i -= 1;
            try self.ops.insert(self.allocator(), 0, captured[i]);
        }
    }

    pub fn toPatchJson(self: *UndoRecorder, parent_allocator: std.mem.Allocator) Error![]const u8 {
        const a = self.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(parent_allocator);
        try buf.appendSlice(parent_allocator, "{\n  \"ops\": [\n");
        for (self.ops.items, 0..) |op, index| {
            if (index > 0) try buf.appendSlice(parent_allocator, ",\n");
            const op_json = try std.json.Stringify.valueAlloc(a, op, .{ .whitespace = .indent_4 });
            defer a.free(op_json);
            try buf.appendSlice(parent_allocator, op_json);
        }
        try buf.appendSlice(parent_allocator, "\n  ]\n}");
        return try buf.toOwnedSlice(parent_allocator);
    }
};

pub fn writeSnapshot(io: std.Io, source_path: []const u8, dest_path: []const u8) Error!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, source_path, std.heap.page_allocator, .unlimited) catch return error.Io;
    defer std.heap.page_allocator.free(bytes);
    io_util.writeFileAtomic(io, dest_path, bytes) catch return error.Io;
}

pub fn defaultSnapshotPath(allocator: std.mem.Allocator, scene_path: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.godot-cli-snapshot", .{scene_path});
}

pub fn recordNodeAddUndo(recorder: *UndoRecorder, path: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "node_remove" });
    try obj.put(a, "path", .{ .string = try a.dupe(u8, path) });
    try obj.put(a, "recursive", .{ .bool = true });
    try recorder.prepend(.{ .object = obj });
}

pub fn recordConnectionAddUndo(recorder: *UndoRecorder, from: []const u8, signal: []const u8, to: []const u8, method: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "connection_remove" });
    try obj.put(a, "from", .{ .string = try a.dupe(u8, from) });
    try obj.put(a, "signal", .{ .string = try a.dupe(u8, signal) });
    try obj.put(a, "to", .{ .string = try a.dupe(u8, to) });
    try obj.put(a, "method", .{ .string = try a.dupe(u8, method) });
    try recorder.prepend(.{ .object = obj });
}

/// Capture every connection that a `connection_remove` will drop, as
/// `connection_add` ops, so the undo patch restores flags and binds too.
pub fn captureConnectionRemoveUndo(
    recorder: *UndoRecorder,
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    from: []const u8,
    signal: []const u8,
    to: []const u8,
    method: ?[]const u8,
) Error!void {
    var connections = scene_connections.collect(allocator, doc) catch return error.OutOfMemory;
    defer connections.deinit(allocator);
    const a = recorder.allocator();
    for (connections.items) |*info| {
        if (!std.mem.eql(u8, info.from_path, from) or !std.mem.eql(u8, info.signal, signal) or !std.mem.eql(u8, info.to_path, to)) continue;
        if (method) |m| if (!std.mem.eql(u8, info.method, m)) continue;
        var obj: std.json.ObjectMap = .{};
        try obj.put(a, "op", .{ .string = "connection_add" });
        try obj.put(a, "from", .{ .string = try a.dupe(u8, info.from_path) });
        try obj.put(a, "signal", .{ .string = try a.dupe(u8, info.signal) });
        try obj.put(a, "to", .{ .string = try a.dupe(u8, info.to_path) });
        try obj.put(a, "method", .{ .string = try a.dupe(u8, info.method) });
        if (info.deferred()) try obj.put(a, "deferred", .{ .bool = true });
        if (info.oneShot()) try obj.put(a, "one_shot", .{ .bool = true });
        if (info.binds) |b| try obj.put(a, "binds", .{ .string = try a.dupe(u8, b) });
        if (info.unbinds) |u| try obj.put(a, "unbinds", .{ .integer = u });
        try recorder.prepend(.{ .object = obj });
    }
}

pub fn recordNodeSetUndo(
    recorder: *UndoRecorder,
    path: []const u8,
    property: []const u8,
    old_value: []const u8,
) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "node_set" });
    try obj.put(a, "path", .{ .string = try a.dupe(u8, path) });
    try obj.put(a, "property", .{ .string = try a.dupe(u8, property) });
    try obj.put(a, "value", .{ .string = try a.dupe(u8, old_value) });
    try recorder.prepend(.{ .object = obj });
}

pub fn recordNodeRenameUndo(recorder: *UndoRecorder, new_path: []const u8, old_name: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "node_rename" });
    try obj.put(a, "path", .{ .string = try a.dupe(u8, new_path) });
    try obj.put(a, "name", .{ .string = try a.dupe(u8, old_name) });
    try recorder.prepend(.{ .object = obj });
}

pub fn recordExtRemoveUndo(recorder: *UndoRecorder, id: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "ext_remove" });
    try obj.put(a, "id", .{ .string = try a.dupe(u8, id) });
    try recorder.prepend(.{ .object = obj });
}

pub fn recordSubRemoveUndo(recorder: *UndoRecorder, id: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "sub_remove" });
    try obj.put(a, "id", .{ .string = try a.dupe(u8, id) });
    try recorder.prepend(.{ .object = obj });
}

pub fn captureExtAddUndo(recorder: *UndoRecorder, allocator: std.mem.Allocator, doc: *const document.Document, id: []const u8) Error!void {
    const section_index = findResourceSection(doc, "ext_resource", id) orelse return error.NodeNotFound;
    const section = doc.sections.items[section_index];
    const res_type = section.header.getString("type") orelse return error.NodeNotFound;
    const path = section.header.getString("path") orelse return error.NodeNotFound;

    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "ext_add" });
    try obj.put(a, "type", .{ .string = try a.dupe(u8, res_type) });
    try obj.put(a, "path", .{ .string = try a.dupe(u8, path) });
    try obj.put(a, "id_hint", .{ .string = try a.dupe(u8, id) });
    if (section.header.getString("uid")) |uid| {
        try obj.put(a, "scene_uid", .{ .string = try a.dupe(u8, uid) });
    }
    try recorder.prepend(.{ .object = obj });
    _ = allocator;
}

pub fn captureSubAddUndo(recorder: *UndoRecorder, allocator: std.mem.Allocator, doc: *const document.Document, id: []const u8) Error!void {
    const section_index = findResourceSection(doc, "sub_resource", id) orelse return error.NodeNotFound;
    const section = doc.sections.items[section_index];
    const res_type = section.header.getString("type") orelse return error.NodeNotFound;

    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "sub_add" });
    try obj.put(a, "type", .{ .string = try a.dupe(u8, res_type) });
    try obj.put(a, "id_hint", .{ .string = try a.dupe(u8, id) });

    if (section.properties.items.len > 0) {
        var props: std.json.ObjectMap = .{};
        for (section.properties.items) |prop| {
            const prop_name = propertyName(prop.raw) orelse continue;
            const prop_value = propertyValue(prop.raw) orelse continue;
            try props.put(a, prop_name, .{ .string = try a.dupe(u8, prop_value) });
        }
        try obj.put(a, "properties", .{ .object = props });
    }

    try recorder.prepend(.{ .object = obj });
    _ = allocator;
}

pub fn recordNodeReparentUndo(recorder: *UndoRecorder, node_path: []const u8, old_parent_path: []const u8) Error!void {
    const a = recorder.allocator();
    var obj: std.json.ObjectMap = .{};
    try obj.put(a, "op", .{ .string = "node_reparent" });
    try obj.put(a, "path", .{ .string = try a.dupe(u8, node_path) });
    try obj.put(a, "parent", .{ .string = try a.dupe(u8, old_parent_path) });
    try recorder.prepend(.{ .object = obj });
}

pub fn captureRemoveUndoOps(
    recorder: *UndoRecorder,
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    node_path: []const u8,
    recursive: bool,
) Error!void {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const target = node_tree.findByPath(&list, node_path) orelse return error.NodeNotFound;

    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    try indices.append(allocator, target.section_index);

    if (recursive) {
        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{target.path});
        defer allocator.free(prefix);
        for (list.nodes) |*node| {
            if (std.mem.startsWith(u8, node.path, prefix)) {
                try indices.append(allocator, node.section_index);
            }
        }
    }

    std.mem.sort(usize, indices.items, {}, struct {
        fn less(_: void, a_idx: usize, b_idx: usize) bool {
            return a_idx < b_idx;
        }
    }.less);

    var captured: std.ArrayList(std.json.Value) = .empty;
    defer captured.deinit(recorder.allocator());

    for (indices.items) |section_index| {
        const op = try nodeSectionToAddOp(recorder.allocator(), doc, &list, section_index);
        try captured.append(recorder.allocator(), op);
    }

    try recorder.prependMany(captured.items);
}

pub fn readNodePropertyRaw(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    node_path: []const u8,
    property_name: []const u8,
) Error!?[]const u8 {
    const section_index = try scene_edit.findNodeSectionIndex(allocator, doc, node_path);
    const section = doc.sections.items[section_index];
    for (section.properties.items) |prop| {
        const name = propertyName(prop.raw) orelse continue;
        if (std.mem.eql(u8, name, property_name)) {
            const value = propertyValue(prop.raw) orelse continue;
            return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn nodeSectionToAddOp(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    list: *const node_tree.NodeList,
    section_index: usize,
) Error!std.json.Value {
    const section = doc.sections.items[section_index];
    const name = section.header.getString("name") orelse return error.NodeNotFound;
    const node_type = section.header.getString("type") orelse "";

    const node = blk: {
        for (list.nodes) |*item| {
            if (item.section_index == section_index) break :blk item;
        }
        return error.NodeNotFound;
    };

    const parent_path = parentViewportPathConst(node.path, list) orelse {
        return error.InvalidNodePath;
    };

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "op", .{ .string = "node_add" });
    try obj.put(allocator, "parent", .{ .string = try allocator.dupe(u8, parent_path) });
    try obj.put(allocator, "name", .{ .string = try allocator.dupe(u8, name) });
    try obj.put(allocator, "type", .{ .string = try allocator.dupe(u8, node_type) });

    if (section.properties.items.len > 0) {
        var props: std.json.ObjectMap = .{};
        for (section.properties.items) |prop| {
            const prop_name = propertyName(prop.raw) orelse continue;
            const prop_value = propertyValue(prop.raw) orelse continue;
            try props.put(allocator, prop_name, .{ .string = try allocator.dupe(u8, prop_value) });
        }
        try obj.put(allocator, "properties", .{ .object = props });
    }

    return .{ .object = obj };
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

fn findResourceSection(doc: *const document.Document, section_name: []const u8, id: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, section_name)) continue;
        if (section.header.getString("id")) |existing| {
            if (std.mem.eql(u8, existing, id)) return index;
        }
    }
    return null;
}

fn propertyName(raw: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return raw[0..sep];
}

fn propertyValue(raw: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return std.mem.trim(u8, raw[sep + 3 ..], &std.ascii.whitespace);
}

test "undo records node add as remove" {
    const allocator = std.testing.allocator;
    var recorder = UndoRecorder.init(allocator);
    defer recorder.deinit();

    try recordNodeAddUndo(&recorder, "/root/Main/Player");
    const json = try recorder.toPatchJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "node_remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/root/Main/Player") != null);
}

test "capture remove undo rebuilds node_add ops" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Player" type="CharacterBody2D" parent="."]
        \\speed = 120.0
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var recorder = UndoRecorder.init(allocator);
    defer recorder.deinit();

    try captureRemoveUndoOps(&recorder, allocator, &doc, "/root/Main/Player", false);
    const json = try recorder.toPatchJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "node_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "speed") != null);
}
