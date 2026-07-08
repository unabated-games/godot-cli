//! External references declared in a scene document (ext_resource sections).

const std = @import("std");
const document = @import("text_format/document.zig");
const project_config = @import("project_config.zig");

pub const Ref = struct {
    section_index: usize,
    section_line: usize,
    id: []const u8,
    res_type: []const u8,
    path: []const u8,
    /// Filesystem path when `project_root` was provided.
    filesystem_path: ?[]const u8 = null,
    exists: ?bool = null,

    pub fn deinit(self: *const Ref, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.res_type);
        allocator.free(self.path);
        if (self.filesystem_path) |path| allocator.free(path);
    }
};

pub const RefList = struct {
    refs: []Ref,

    pub fn deinit(self: *RefList, allocator: std.mem.Allocator) void {
        for (self.refs) |*item| item.deinit(allocator);
        allocator.free(self.refs);
    }
};

pub const CollectError = error{
    OutOfMemory,
};

pub fn collectExtResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    doc: *const document.Document,
    project_root: ?[]const u8,
) CollectError!RefList {
    var items: std.ArrayList(Ref) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const id = section.header.getString("id") orelse continue;
        const path = section.header.getString("path") orelse continue;
        const res_type = section.header.getString("type") orelse "";

        var ref: Ref = .{
            .section_index = index,
            .section_line = section.line,
            .id = try allocator.dupe(u8, id),
            .res_type = try allocator.dupe(u8, res_type),
            .path = try allocator.dupe(u8, path),
        };

        if (project_root) |root| {
            if (try project_config.resPathToFilesystem(allocator, root, path)) |fs_path| {
                ref.filesystem_path = fs_path;
                ref.exists = blk: {
                    std.Io.Dir.cwd().access(io, fs_path, .{}) catch {
                        break :blk false;
                    };
                    break :blk true;
                };
            }
        }

        try items.append(allocator, ref);
    }

    return .{ .refs = try items.toOwnedSlice(allocator) };
}

pub fn refsToJsonArray(allocator: std.mem.Allocator, refs: []const Ref) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (refs) |*ref| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "section_index", .{ .integer = @intCast(ref.section_index) });
        try row.put(allocator, "section_line", .{ .integer = @intCast(ref.section_line) });
        try row.put(allocator, "id", .{ .string = try allocator.dupe(u8, ref.id) });
        try row.put(allocator, "type", .{ .string = try allocator.dupe(u8, ref.res_type) });
        try row.put(allocator, "path", .{ .string = try allocator.dupe(u8, ref.path) });
        if (ref.filesystem_path) |fs_path| {
            try row.put(allocator, "filesystem_path", .{ .string = try allocator.dupe(u8, fs_path) });
        }
        if (ref.exists) |exists| {
            try row.put(allocator, "exists", .{ .bool = exists });
        }
        try arr.append(.{ .object = row });
    }
    return arr;
}

test "collect ext resources with project root" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://id_reference.gd" id="1_x"]
        \\
        \\[node name="Root" type="Node3D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var list = try collectExtResources(allocator, std.testing.io, &doc, "test_fixtures/project");
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), list.refs.len);
    try std.testing.expectEqualStrings("res://id_reference.gd", list.refs[0].path);
    try std.testing.expect(list.refs[0].exists == true);
}
