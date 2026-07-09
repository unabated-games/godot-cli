//! Resolve Godot `uid://` text for `ext_resource` entries from project files.

const std = @import("std");
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");
const scene_instance = @import("scene_instance.zig");

pub const Error = error{
    OutOfMemory,
};

/// Best-effort UID for an `ext_resource` path. Returns null when unknown.
pub fn resolveExtResourceUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    res_path: []const u8,
) Error!?[]const u8 {
    const root = project_root orelse return null;

    if (std.mem.endsWith(u8, res_path, ".tscn") or std.mem.endsWith(u8, res_path, ".tres")) {
        return scene_instance.readSceneUidFromResPath(allocator, io, root, res_path) catch return null;
    }

    const fs_path = try project_config.resPathToFilesystem(allocator, root, res_path) orelse return null;
    defer allocator.free(fs_path);

    if (readImportFileUid(allocator, io, fs_path)) |uid| return uid;

    const cache_path = uid_cache.defaultCachePath(allocator, root) catch return null;
    defer allocator.free(cache_path);
    if (uid_cache.loadFromFile(allocator, io, cache_path)) |loaded| {
        var cache = loaded;
        defer cache.deinit(allocator);
        if (cache.idForPath(res_path)) |id| {
            return try resource_uid.idToText(allocator, id);
        }
    } else |_| {}

    const project_name = project_config.readProjectName(allocator, io, root) catch return null;
    defer allocator.free(project_name);

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, fs_path, allocator, .unlimited) catch return null;
    defer allocator.free(file_bytes);

    const id = try resource_uid.createIdForPath(allocator, project_name, res_path, file_bytes);
    return try resource_uid.idToText(allocator, id);
}

fn readImportFileUid(allocator: std.mem.Allocator, io: std.Io, fs_path: []const u8) ?[]const u8 {
    const import_path = std.fmt.allocPrint(allocator, "{s}.import", .{fs_path}) catch return null;
    defer allocator.free(import_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, import_path, allocator, .unlimited) catch return null;
    defer allocator.free(bytes);

    return parseUidFromImportBytes(allocator, bytes);
}

pub fn parseUidFromImportBytes(allocator: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
    const needle = "uid=\"uid://";
    const start = std.mem.indexOf(u8, bytes, needle) orelse return null;
    const uid_start = start + "uid=\"".len;
    const end = std.mem.indexOfPos(u8, bytes, uid_start, "\"") orelse return null;
    return allocator.dupe(u8, bytes[uid_start..end]) catch null;
}

test "parse import uid bytes" {
    const allocator = std.testing.allocator;
    const import_text =
        \\[remap]
        \\
        \\importer="texture"
        \\type="CompressedTexture2D"
        \\uid="uid://cl5i3ef5rs1dv"
        \\path="res://.godot/imported/icon.svg.ctex"
    ;

    const uid = parseUidFromImportBytes(allocator, import_text);
    defer if (uid) |value| allocator.free(value);
    try std.testing.expect(uid != null);
    try std.testing.expectEqualStrings("uid://cl5i3ef5rs1dv", uid.?);
}
