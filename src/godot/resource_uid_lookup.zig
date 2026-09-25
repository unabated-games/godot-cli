//! Resolve Godot `uid://` text for `ext_resource` entries from project files.

const std = @import("std");
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");
const scene_instance = @import("scene_instance.zig");
const binary_resource = @import("binary_resource.zig");

pub const Error = error{
    OutOfMemory,
};

/// Best-effort UID for an `ext_resource` path. Returns null when unknown.
/// The uid Godot itself recorded for a path: a scene or resource header, a
/// `.uid` sidecar, or a `.import` file. Null when none exists, with no guess.
pub fn resolveRecordedExtResourceUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    res_path: []const u8,
) Error!?[]const u8 {
    if (std.mem.endsWith(u8, res_path, ".tscn") or std.mem.endsWith(u8, res_path, ".tres")) {
        return scene_instance.readSceneUidFromResPath(allocator, io, project_root, res_path) catch return null;
    }
    const fs_path = try project_config.resPathToFilesystem(allocator, project_root, res_path) orelse return null;
    defer allocator.free(fs_path);
    // A binary resource (`.res`, `.scn`) keeps its UID in its own header, as a
    // text one does in its first line; it has no sidecar.
    if (binary_resource.isBinaryResourceFile(io, fs_path)) return readBinaryUid(allocator, io, fs_path);
    // Godot 4.4+ keeps a script's UID in a `.uid` sidecar, assigned once and
    // never recomputed, so it outranks anything derived from the file.
    if (readSidecarUid(allocator, io, fs_path)) |uid| return uid;
    if (readImportFileUid(allocator, io, fs_path)) |uid| return uid;
    return null;
}

pub fn readSceneUidFromResPath(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, res_path: []const u8) Error!?[]const u8 {
    return scene_instance.readSceneUidFromResPath(allocator, io, project_root, res_path) catch return null;
}

pub fn resolveExtResourceUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    res_path: []const u8,
) Error!?[]const u8 {
    const root = project_root orelse return null;

    if (try resolveRecordedExtResourceUid(allocator, io, root, res_path)) |uid| return uid;
    if (std.mem.endsWith(u8, res_path, ".tscn") or std.mem.endsWith(u8, res_path, ".tres")) return null;

    const fs_path = try project_config.resPathToFilesystem(allocator, root, res_path) orelse return null;
    defer allocator.free(fs_path);
    // Its header was the answer, and it had none. Hashing the bytes would
    // invent one: they contain the UID slot, so the hash never matches what
    // Godot assigned, and every later save would rewrite a correct reference.
    if (binary_resource.isBinaryResourceFile(io, fs_path)) return null;

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

/// The UID in a binary resource's header as `uid://` text. Null when the
/// header records none or does not parse.
pub fn readBinaryUid(allocator: std.mem.Allocator, io: std.Io, fs_path: []const u8) Error!?[]const u8 {
    var header = binary_resource.readHeader(allocator, io, fs_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer header.deinit(allocator);
    const id = header.uid orelse return null;
    return try resource_uid.idToText(allocator, id);
}

/// `<file>.uid`, holding one `uid://...` line.
pub fn readSidecarUid(allocator: std.mem.Allocator, io: std.Io, fs_path: []const u8) ?[]const u8 {
    const sidecar_path = std.fmt.allocPrint(allocator, "{s}.uid", .{fs_path}) catch return null;
    defer allocator.free(sidecar_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, sidecar_path, allocator, .unlimited) catch return null;
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, "uid://")) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// Rewrite `uid=` on every ext_resource that has one, when the project knows a
/// different value. A component copied between projects carries the old
/// project's UIDs, and Godot warns on every load until they are corrected.
/// Returns how many were changed.
pub fn refreshExtResourceUids(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    doc: *@import("text_format/document.zig").Document,
) Error!usize {
    var changed: usize = 0;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const res_path = section.header.getString("path") orelse continue;
        if (section.header.getString("uid")) |declared| {
            const current = (try resolveExtResourceUid(allocator, io, project_root, res_path)) orelse continue;
            defer allocator.free(current);
            if (std.mem.eql(u8, declared, current)) continue;
            section.header.setUidField(allocator, current) catch return error.OutOfMemory;
            changed += 1;
        } else {
            // A reference to a scene or resource gains the uid from that file's
            // header, as the editor writes. Script and asset references are
            // left alone: Godot's own headless save (the round-trip fixture)
            // writes those without a uid, and the fixture is the ground truth.
            if (!std.mem.endsWith(u8, res_path, ".tscn") and !std.mem.endsWith(u8, res_path, ".tres")) continue;
            const known = (try resolveRecordedExtResourceUid(allocator, io, project_root, res_path)) orelse continue;
            defer allocator.free(known);
            section.header.setUidField(allocator, known) catch return error.OutOfMemory;
            changed += 1;
        }
    }
    return changed;
}

/// The UID in `<file>.import`, where Godot keeps an imported asset's.
pub fn readImportFileUid(allocator: std.mem.Allocator, io: std.Io, fs_path: []const u8) ?[]const u8 {
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

test "a binary resource's uid comes from its header, never a hash of its bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const got = (try resolveExtResourceUid(allocator, io, "test_fixtures/project", "res://resources/mesh_compressed_godot_saved.res")).?;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("uid://ci8fbl838ce7m", got);
    // Recording none is an answer. A hash would invent a UID Godot never
    // assigned, and saving it would break the reference.
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveExtResourceUid(allocator, io, "test_fixtures/project", "res://resources/mesh_no_uid_godot_saved.res"));
}

test "a save keeps a correct binary resource uid and repairs a wrong one" {
    // Without a uid cache (a fresh clone), every save with a project root
    // once replaced these with a hash of the file's bytes.
    const allocator = std.testing.allocator;
    const document = @import("text_format/document.zig");
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="BoxMesh" uid="uid://bc628hhe4x5yp" path="res://resources/mesh_godot_saved.res" id="1_box"]
        \\[ext_resource type="SphereMesh" uid="uid://byggqned6p7ih" path="res://resources/mesh_compressed_godot_saved.res" id="2_ball"]
        \\
        \\[node name="Root" type="Node3D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const changed = try refreshExtResourceUids(allocator, std.testing.io, "test_fixtures/project", &doc);
    try std.testing.expectEqual(@as(usize, 1), changed);
    try std.testing.expectEqualStrings("uid://bc628hhe4x5yp", doc.sections.items[1].header.getString("uid").?);
    try std.testing.expectEqualStrings("uid://ci8fbl838ce7m", doc.sections.items[2].header.getString("uid").?);
}
