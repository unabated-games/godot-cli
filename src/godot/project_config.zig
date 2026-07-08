//! Minimal Godot `project.godot` helpers for validation and UID checks.

const std = @import("std");

pub const ReadError = error{
    Io,
    OutOfMemory,
    ProjectNameNotFound,
};

/// Read `application/config/name` from `project.godot` at `project_root/project.godot`.
pub fn readProjectName(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8) ReadError![]u8 {
    const project_file = try std.fs.path.join(allocator, &.{ project_root, "project.godot" });
    defer allocator.free(project_file);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, project_file, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);

    var in_application = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == ';') continue;

        if (trimmed[0] == '[') {
            in_application = std.mem.eql(u8, trimmed, "[application]");
            continue;
        }

        if (!in_application) continue;
        const prefix = "config/name=";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;

        const value = trimmed[prefix.len..];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return try allocator.dupe(u8, value[1 .. value.len - 1]);
        }
        return try allocator.dupe(u8, value);
    }

    return error.ProjectNameNotFound;
}

/// Map a filesystem path under `project_root` to a Godot `res://` path.
pub fn filesystemToResPath(allocator: std.mem.Allocator, project_root: []const u8, file_path: []const u8) !?[]u8 {
    const norm_root = try std.fs.path.resolve(allocator, &.{project_root});
    defer allocator.free(norm_root);
    const norm_file = try std.fs.path.resolve(allocator, &.{file_path});
    defer allocator.free(norm_file);

    const rel = std.fs.path.relative(allocator, ".", null, norm_root, norm_file) catch return null;
    defer allocator.free(rel);

    if (rel.len == 0 or rel[0] == '.') return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "res://");
    for (rel) |c| {
        try out.append(allocator, if (c == '\\') '/' else c);
    }
    return try out.toOwnedSlice(allocator);
}

/// Resolve `res://path` to a filesystem path under `project_root`.
pub fn resPathToFilesystem(allocator: std.mem.Allocator, project_root: []const u8, res_path: []const u8) !?[]u8 {
    const prefix = "res://";
    if (!std.mem.startsWith(u8, res_path, prefix)) return null;
    const rel = res_path[prefix.len..];
    if (rel.len == 0) return null;

    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);

    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return null;
        try components.append(allocator, part);
    }

    var path_parts: std.ArrayList([]const u8) = .empty;
    defer path_parts.deinit(allocator);
    try path_parts.append(allocator, project_root);
    try path_parts.appendSlice(allocator, components.items);

    return try std.fs.path.join(allocator, path_parts.items);
}

test "read project name from fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const name = try readProjectName(allocator, io, "test_fixtures/project");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("TestProject", name);
}

test "filesystem to res path" {
    const allocator = std.testing.allocator;
    const res = try filesystemToResPath(allocator, "test_fixtures/project", "test_fixtures/project/test.tscn");
    defer allocator.free(res.?);
    try std.testing.expectEqualStrings("res://test.tscn", res.?);
}
