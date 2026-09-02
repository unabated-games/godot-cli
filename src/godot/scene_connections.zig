//! Signal connections: the `[connection ...]` sections Godot writes when a
//! signal is connected in the editor.
//!
//! ```
//! [connection signal="pressed" from="Box/Resume" to="." method="_on_resume_pressed"]
//! [connection signal="pressed" from="Box/Quit" to="." method="_on_quit" flags=3 binds= ["quit"]]
//! ```
//!
//! `from` and `to` are paths relative to the scene root, `.` for the root
//! itself, the same shape as a node's `parent` attribute. `flags` carries
//! Godot's ConnectFlags with the persist bit set, and is omitted when it is
//! only that bit. Connections follow the last node with no blank lines between
//! them (see `text_format/writer.zig`).

const std = @import("std");
const document = @import("text_format/document.zig");
const tag = @import("text_format/tag.zig");
const node_tree = @import("node_tree.zig");

pub const Error = error{
    OutOfMemory,
    NoSceneRoot,
    NodeNotFound,
    DuplicateConnection,
    ConnectionNotFound,
    InvalidNodePath,
} || node_tree.Error || document.EditError;

/// Godot's Object.ConnectFlags.
pub const flag_deferred: i64 = 1;
pub const flag_persist: i64 = 2;
pub const flag_one_shot: i64 = 4;

pub const ConnectionInfo = struct {
    section_index: usize,
    section_line: usize,
    signal: []const u8,
    /// Root-relative paths as written in the file.
    from_attr: []const u8,
    to_attr: []const u8,
    /// Viewport paths, `/root/Menu/Box/Resume`.
    from_path: []const u8,
    to_path: []const u8,
    method: []const u8,
    flags: i64,
    /// Verbatim array text, `["quit"]`, or null.
    binds: ?[]const u8,
    unbinds: ?i64,

    pub fn deinit(self: *const ConnectionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.signal);
        allocator.free(self.from_attr);
        allocator.free(self.to_attr);
        allocator.free(self.from_path);
        allocator.free(self.to_path);
        allocator.free(self.method);
        if (self.binds) |b| allocator.free(b);
    }

    pub fn deferred(self: *const ConnectionInfo) bool {
        return self.flags & flag_deferred != 0;
    }

    pub fn oneShot(self: *const ConnectionInfo) bool {
        return self.flags & flag_one_shot != 0;
    }
};

pub const ConnectionList = struct {
    items: []ConnectionInfo,

    pub fn deinit(self: *ConnectionList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const AddOptions = struct {
    deferred: bool = false,
    one_shot: bool = false,
    /// Verbatim array text, e.g. `["quit"]`.
    binds: ?[]const u8 = null,
    unbinds: ?i64 = null,
};

fn sceneRootPath(list: *const node_tree.NodeList) Error![]const u8 {
    for (list.nodes) |*node| {
        if (node.parent.len == 0) return node.path;
    }
    return error.NoSceneRoot;
}

fn attrToViewportPath(allocator: std.mem.Allocator, root_path: []const u8, attr: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, attr, ".")) return try allocator.dupe(u8, root_path);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, attr });
}

fn viewportPathToAttr(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, path, root_path)) return try allocator.dupe(u8, ".");
    if (path.len > root_path.len and std.mem.startsWith(u8, path, root_path) and path[root_path.len] == '/') {
        return try allocator.dupe(u8, path[root_path.len + 1 ..]);
    }
    return error.InvalidNodePath;
}

pub fn collect(allocator: std.mem.Allocator, doc: *const document.Document) Error!ConnectionList {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);
    const root_path = if (list.nodes.len == 0) "" else try sceneRootPath(&list);

    var items: std.ArrayList(ConnectionInfo) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        const signal = section.header.getString("signal") orelse continue;
        const from_attr = section.header.getString("from") orelse continue;
        const to_attr = section.header.getString("to") orelse continue;
        const method = section.header.getString("method") orelse continue;

        const from_path = try attrToViewportPath(allocator, root_path, from_attr);
        errdefer allocator.free(from_path);
        const to_path = try attrToViewportPath(allocator, root_path, to_attr);
        errdefer allocator.free(to_path);

        try items.append(allocator, .{
            .section_index = index,
            .section_line = section.line,
            .signal = try allocator.dupe(u8, signal),
            .from_attr = try allocator.dupe(u8, from_attr),
            .to_attr = try allocator.dupe(u8, to_attr),
            .from_path = from_path,
            .to_path = to_path,
            .method = try allocator.dupe(u8, method),
            .flags = section.header.getInteger("flags") orelse flag_persist,
            .binds = if (section.header.getRaw("binds") orelse section.header.getString("binds")) |b| try allocator.dupe(u8, b) else null,
            .unbinds = section.header.getInteger("unbinds"),
        });
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

/// Add a connection. `from_path` and `to_path` are viewport paths; both nodes
/// must exist. Returns the new section index.
pub fn add(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    from_path: []const u8,
    signal: []const u8,
    to_path: []const u8,
    method: []const u8,
    options: AddOptions,
) Error!usize {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);
    const root_path = try sceneRootPath(&list);
    if (node_tree.findByPath(&list, from_path) == null) return error.NodeNotFound;
    if (node_tree.findByPath(&list, to_path) == null) return error.NodeNotFound;

    const from_attr = try viewportPathToAttr(allocator, root_path, from_path);
    defer allocator.free(from_attr);
    const to_attr = try viewportPathToAttr(allocator, root_path, to_path);
    defer allocator.free(to_attr);

    var last_connection: ?usize = null;
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        last_connection = index;
        if (std.mem.eql(u8, section.header.getString("signal") orelse "", signal) and
            std.mem.eql(u8, section.header.getString("from") orelse "", from_attr) and
            std.mem.eql(u8, section.header.getString("to") orelse "", to_attr) and
            std.mem.eql(u8, section.header.getString("method") orelse "", method))
        {
            return error.DuplicateConnection;
        }
    }

    var header = tag.Tag{ .name = try allocator.dupe(u8, "connection"), .fields = .{} };
    errdefer header.deinit(allocator);
    try header.setStringField(allocator, "signal", signal);
    try header.setStringField(allocator, "from", from_attr);
    try header.setStringField(allocator, "to", to_attr);
    try header.setStringField(allocator, "method", method);

    var flags: i64 = flag_persist;
    if (options.deferred) flags |= flag_deferred;
    if (options.one_shot) flags |= flag_one_shot;
    if (flags != flag_persist) try header.setIntegerField(allocator, "flags", flags);
    if (options.binds) |binds| try header.setRawField(allocator, "binds", binds);
    if (options.unbinds) |unbinds| {
        if (unbinds > 0) try header.setIntegerField(allocator, "unbinds", unbinds);
    }

    // After the last connection, else directly after the last node. A run of
    // connections is written contiguously; the first one gets the blank line.
    const insert_at = if (last_connection) |index|
        index + 1
    else if (document.lastNodeSectionIndex(doc)) |index|
        index + 1
    else
        doc.sections.items.len;

    try document.insertSection(doc, allocator, insert_at, .{
        .line = 0,
        .leading_blank_lines = if (last_connection != null) 0 else 1,
        .header = header,
        .properties = .empty,
    });
    return insert_at;
}

/// Remove every connection matching from, signal, to, and (when given)
/// method. Returns how many were removed.
pub fn remove(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    from_path: []const u8,
    signal: []const u8,
    to_path: []const u8,
    method: ?[]const u8,
) Error!usize {
    var connections = try collect(allocator, doc);
    defer connections.deinit(allocator);

    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    for (connections.items) |*info| {
        if (!std.mem.eql(u8, info.from_path, from_path)) continue;
        if (!std.mem.eql(u8, info.signal, signal)) continue;
        if (!std.mem.eql(u8, info.to_path, to_path)) continue;
        if (method) |m| if (!std.mem.eql(u8, info.method, m)) continue;
        try indices.append(allocator, info.section_index);
    }
    if (indices.items.len == 0) return error.ConnectionNotFound;

    try removeSections(allocator, doc, indices.items);
    return indices.items.len;
}

/// Section indices of connections whose `from` or `to` is `attr_prefix` or a
/// node under it. Used when a node is removed, so the scene does not keep
/// connections to nodes that no longer exist (the editor drops them too).
pub fn referencingSectionIndices(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    attr_prefix: []const u8,
) Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        const from_attr = section.header.getString("from") orelse "";
        const to_attr = section.header.getString("to") orelse "";
        if (attrMatchesPrefix(from_attr, attr_prefix) or attrMatchesPrefix(to_attr, attr_prefix)) {
            try out.append(allocator, index);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Rewrite `from` and `to` after a node moved from `old_prefix` to
/// `new_prefix` (root-relative attrs, as `parent=` uses).
pub fn rewritePaths(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    old_prefix: []const u8,
    new_prefix: []const u8,
) Error!void {
    if (old_prefix.len == 0) return;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        for ([_][]const u8{ "from", "to" }) |key| {
            const attr = section.header.getString(key) orelse continue;
            if (std.mem.eql(u8, attr, old_prefix)) {
                try section.header.setStringField(allocator, key, new_prefix);
            } else if (attr.len > old_prefix.len and std.mem.startsWith(u8, attr, old_prefix) and attr[old_prefix.len] == '/') {
                const rewritten = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ new_prefix, attr[old_prefix.len + 1 ..] });
                defer allocator.free(rewritten);
                try section.header.setStringField(allocator, key, rewritten);
            }
        }
    }
}

fn attrMatchesPrefix(attr: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (std.mem.eql(u8, attr, prefix)) return true;
    return attr.len > prefix.len and std.mem.startsWith(u8, attr, prefix) and attr[prefix.len] == '/';
}

/// Remove sections by index, highest first, keeping the blank line that
/// separates the connection block from the nodes above it.
fn removeSections(allocator: std.mem.Allocator, doc: *document.Document, indices: []usize) Error!void {
    std.mem.sort(usize, indices, {}, struct {
        fn desc(_: void, a: usize, b: usize) bool {
            return a > b;
        }
    }.desc);
    for (indices) |index| {
        const blank = doc.sections.items[index].leading_blank_lines;
        var section = try document.removeSection(doc, index);
        section.deinit(allocator);
        if (blank > 0 and index < doc.sections.items.len) {
            const next = &doc.sections.items[index];
            if (std.mem.eql(u8, next.header.name, "connection") and next.leading_blank_lines == 0) {
                next.leading_blank_lines = blank;
            }
        }
    }
}

pub const MissingEndpoint = struct {
    section_line: usize,
    /// `from` or `to`.
    field: []const u8,
    attr: []const u8,
};

/// Connections whose `from` or `to` names a node that is not in the scene.
/// Godot logs a warning per load and the signal never fires; the editor drops
/// these when the node is deleted, so their presence means a hand edit.
pub fn missingEndpoints(allocator: std.mem.Allocator, doc: *const document.Document) Error![]MissingEndpoint {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);
    const root_path = if (list.nodes.len == 0) "" else try sceneRootPath(&list);

    var out: std.ArrayList(MissingEndpoint) = .empty;
    errdefer out.deinit(allocator);
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        for ([_][]const u8{ "from", "to" }) |key| {
            const attr = section.header.getString(key) orelse continue;
            const path = try attrToViewportPath(allocator, root_path, attr);
            defer allocator.free(path);
            if (node_tree.findByPath(&list, path) == null) {
                try out.append(allocator, .{ .section_line = section.line, .field = key, .attr = attr });
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn toJson(allocator: std.mem.Allocator, info: *const ConnectionInfo) !std.json.Value {
    var row: std.json.ObjectMap = .{};
    try row.put(allocator, "signal", .{ .string = try allocator.dupe(u8, info.signal) });
    try row.put(allocator, "from", .{ .string = try allocator.dupe(u8, info.from_path) });
    try row.put(allocator, "to", .{ .string = try allocator.dupe(u8, info.to_path) });
    try row.put(allocator, "method", .{ .string = try allocator.dupe(u8, info.method) });
    try row.put(allocator, "flags", .{ .integer = info.flags });
    try row.put(allocator, "deferred", .{ .bool = info.deferred() });
    try row.put(allocator, "one_shot", .{ .bool = info.oneShot() });
    try row.put(allocator, "binds", if (info.binds) |b| .{ .string = try allocator.dupe(u8, b) } else .null);
    try row.put(allocator, "unbinds", if (info.unbinds) |u| .{ .integer = u } else .null);
    try row.put(allocator, "section_line", .{ .integer = @intCast(info.section_line) });
    return .{ .object = row };
}

test "collect reads Godot's connection variants" {
    const allocator = std.testing.allocator;
    const text =
        \\[gd_scene format=3]
        \\
        \\[node name="Menu" type="Control"]
        \\
        \\[node name="Box" type="VBoxContainer" parent="."]
        \\
        \\[node name="Quit" type="Button" parent="Box"]
        \\
        \\[connection signal="pressed" from="Box/Quit" to="." method="_on_quit" flags=3 binds= ["quit"]]
        \\[connection signal="ready" from="." to="Box" method="_on_ready" flags=6 unbinds=1]
        \\
    ;
    var doc = try document.parseBytes(allocator, text);
    defer doc.deinit(allocator);

    var connections = try collect(allocator, &doc);
    defer connections.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), connections.items.len);
    const quit = connections.items[0];
    try std.testing.expectEqualStrings("/root/Menu/Box/Quit", quit.from_path);
    try std.testing.expectEqualStrings("/root/Menu", quit.to_path);
    try std.testing.expect(quit.deferred());
    try std.testing.expectEqualStrings("[\"quit\"]", quit.binds.?);
    try std.testing.expect(connections.items[1].oneShot());
    try std.testing.expectEqual(@as(i64, 1), connections.items[1].unbinds.?);
}

test "add writes what Godot writes and remove restores the blank line" {
    const allocator = std.testing.allocator;
    const writer = @import("text_format/writer.zig");
    const text =
        \\[gd_scene format=3]
        \\
        \\[node name="Menu" type="Control"]
        \\
        \\[node name="Resume" type="Button" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, text);
    defer doc.deinit(allocator);

    _ = try add(allocator, &doc, "/root/Menu/Resume", "pressed", "/root/Menu", "_on_resume", .{});
    _ = try add(allocator, &doc, "/root/Menu/Resume", "pressed", "/root/Menu", "_on_quit", .{ .deferred = true, .binds = "[\"quit\"]" });
    try std.testing.expectError(error.DuplicateConnection, add(allocator, &doc, "/root/Menu/Resume", "pressed", "/root/Menu", "_on_resume", .{}));
    try std.testing.expectError(error.NodeNotFound, add(allocator, &doc, "/root/Menu/Nope", "pressed", "/root/Menu", "_on_resume", .{}));

    const out = try writer.writeDocument(allocator, &doc);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        \\[gd_scene format=3]
        \\
        \\[node name="Menu" type="Control"]
        \\
        \\[node name="Resume" type="Button" parent="."]
        \\
        \\[connection signal="pressed" from="Resume" to="." method="_on_resume"]
        \\[connection signal="pressed" from="Resume" to="." method="_on_quit" flags=3 binds= ["quit"]]
        \\
    , out);

    // Removing the first connection hands its blank line to the next one.
    _ = try remove(allocator, &doc, "/root/Menu/Resume", "pressed", "/root/Menu", "_on_resume");
    const after = try writer.writeDocument(allocator, &doc);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "parent=\".\"]\n\n[connection signal=\"pressed\" from=\"Resume\" to=\".\" method=\"_on_quit\"") != null);
}

test "rewritePaths follows a rename" {
    const allocator = std.testing.allocator;
    const text =
        \\[gd_scene format=3]
        \\
        \\[node name="Menu" type="Control"]
        \\
        \\[node name="Box" type="VBoxContainer" parent="."]
        \\
        \\[node name="Quit" type="Button" parent="Box"]
        \\
        \\[connection signal="pressed" from="Box/Quit" to="Box" method="_on_quit"]
        \\
    ;
    var doc = try document.parseBytes(allocator, text);
    defer doc.deinit(allocator);
    try rewritePaths(allocator, &doc, "Box", "Panel");
    const header = doc.sections.items[doc.sections.items.len - 1].header;
    try std.testing.expectEqualStrings("Panel/Quit", header.getString("from").?);
    try std.testing.expectEqualStrings("Panel", header.getString("to").?);
}
