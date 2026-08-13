//! Repair catalog manifests whose scene has moved.
//!
//! A manifest's `scene` is a plain path string, and Godot does not rewrite it
//! when a `.tscn` is moved — its dependency tracking only follows `ext_resource`
//! and `uid://` references, not arbitrary string properties. So moving a scene
//! leaves the manifest pointing at nothing and `catalog validate` reporting
//! `scene_not_found`.
//!
//! `scene_uid` is the anchor that survives the move: the uid stays in the
//! scene's `[gd_scene]` header, and Godot's own `.godot/uid_cache.bin` maps it
//! to the current path. Relinking is therefore a uid lookup followed by the same
//! update `catalog add --update` performs.
//!
//! This only works when the uid cache reflects the move, which means the project
//! has been opened in Godot since. A `git mv` with the editor closed leaves the
//! cache stale until Godot next scans.

const std = @import("std");
const catalog_add = @import("catalog_add.zig");
const catalog_scan = @import("catalog_scan.zig");
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");

pub const Error = catalog_scan.ScanError || catalog_add.Error;

pub const Status = enum {
    /// Scene resolves; nothing to do.
    ok,
    /// Scene was missing and the manifest now points at the uid's current path.
    relinked,
    /// Scene is missing and the uid could not be resolved to an existing file.
    unresolved,
    /// Scene is missing and the manifest is a `.tres`, which this does not edit.
    manual,

    pub fn jsonString(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .relinked => "relinked",
            .unresolved => "unresolved",
            .manual => "manual",
        };
    }
};

pub const EntryResult = struct {
    id: []const u8,
    manifest_path: []const u8,
    status: Status,
    old_scene: []const u8,
    new_scene: []const u8 = "",
    reason: []const u8 = "",

    pub fn deinit(self: *EntryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.manifest_path);
        allocator.free(self.old_scene);
        allocator.free(self.new_scene);
        allocator.free(self.reason);
    }
};

pub const Result = struct {
    project_root: []const u8,
    checked: usize = 0,
    relinked: usize = 0,
    unresolved: usize = 0,
    manual: usize = 0,
    entries: []EntryResult,

    /// True when a manifest is still pointing at a missing scene afterwards.
    pub fn hasUnrepaired(self: *const Result) bool {
        return self.unresolved > 0 or self.manual > 0;
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.project_root);
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn relinkProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
    dry_run: bool,
) Error!Result {
    var scan = try catalog_scan.scanProject(allocator, io, project_root, cache);
    defer scan.deinit(allocator);

    var entries: std.ArrayList(EntryResult) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var relinked: usize = 0;
    var unresolved: usize = 0;
    var manual: usize = 0;

    for (scan.entries) |*entry| {
        if (!try sceneMissing(allocator, io, project_root, entry.scene)) {
            try entries.append(allocator, .{
                .id = try allocator.dupe(u8, entry.id),
                .manifest_path = try allocator.dupe(u8, entry.manifest_path),
                .status = .ok,
                .old_scene = try allocator.dupe(u8, entry.scene),
                .new_scene = try allocator.dupe(u8, ""),
                .reason = try allocator.dupe(u8, ""),
            });
            continue;
        }

        if (entry.format == .tres) {
            manual += 1;
            try entries.append(allocator, .{
                .id = try allocator.dupe(u8, entry.id),
                .manifest_path = try allocator.dupe(u8, entry.manifest_path),
                .status = .manual,
                .old_scene = try allocator.dupe(u8, entry.scene),
                .new_scene = try allocator.dupe(u8, ""),
                .reason = try allocator.dupe(u8, "tres manifests are not rewritten; use resource set-property --section resource --property scene"),
            });
            continue;
        }

        const resolved = try resolveByUid(allocator, io, project_root, cache, entry.scene_uid);
        const new_scene = resolved orelse {
            unresolved += 1;
            const reason = if (entry.scene_uid.len == 0)
                "manifest has no scene_uid to resolve"
            else
                "scene_uid is not in the uid cache, or resolves to a file that does not exist (open the project in Godot to refresh .godot/uid_cache.bin)";
            try entries.append(allocator, .{
                .id = try allocator.dupe(u8, entry.id),
                .manifest_path = try allocator.dupe(u8, entry.manifest_path),
                .status = .unresolved,
                .old_scene = try allocator.dupe(u8, entry.scene),
                .new_scene = try allocator.dupe(u8, ""),
                .reason = try allocator.dupe(u8, reason),
            });
            continue;
        };
        defer allocator.free(new_scene);

        // Reuse the update path so prose, id, and signal rows are handled the
        // same way `catalog add --update` handles them.
        var updated = try catalog_add.addManifest(allocator, io, project_root, .{
            .scene = new_scene,
            .update = true,
            .output = entry.manifest_path,
            .dry_run = dry_run,
        });
        defer updated.deinit(allocator);

        relinked += 1;
        try entries.append(allocator, .{
            .id = try allocator.dupe(u8, updated.id),
            .manifest_path = try allocator.dupe(u8, entry.manifest_path),
            .status = .relinked,
            .old_scene = try allocator.dupe(u8, entry.scene),
            .new_scene = try allocator.dupe(u8, new_scene),
            .reason = try allocator.dupe(u8, ""),
        });
    }

    const checked = entries.items.len;
    return .{
        .project_root = try allocator.dupe(u8, scan.project_root),
        .checked = checked,
        .relinked = relinked,
        .unresolved = unresolved,
        .manual = manual,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn sceneMissing(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    scene: []const u8,
) Error!bool {
    if (scene.len == 0) return true;
    const fs_maybe = project_config.resPathToFilesystem(allocator, project_root, scene) catch return true;
    const fs_path = fs_maybe orelse return true;
    defer allocator.free(fs_path);
    std.Io.Dir.cwd().access(io, fs_path, .{}) catch return true;
    return false;
}

/// `uid://…` to the `res://` path it currently points at, if that file exists.
fn resolveByUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
    scene_uid: []const u8,
) Error!?[]const u8 {
    if (scene_uid.len == 0) return null;
    const loaded_cache = cache orelse return null;

    const id = resource_uid.textToId(scene_uid);
    if (id == resource_uid.invalid_id) return null;

    const res_path = loaded_cache.pathForId(id) orelse return null;

    // The cache can name a path that no longer exists if it went stale in the
    // other direction; only offer a target we can actually see.
    const fs_maybe = project_config.resPathToFilesystem(allocator, project_root, res_path) catch return null;
    const fs_path = fs_maybe orelse return null;
    defer allocator.free(fs_path);
    std.Io.Dir.cwd().access(io, fs_path, .{}) catch return null;

    return try allocator.dupe(u8, res_path);
}

test "resolveByUid returns null without a cache" {
    const allocator = std.testing.allocator;
    const got = try resolveByUid(allocator, std.testing.io, "test_fixtures/project", null, "uid://byhqeak2spha2");
    try std.testing.expect(got == null);
}

test "resolveByUid finds the fixture scene through the uid cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cache_path = try uid_cache.defaultCachePath(allocator, "test_fixtures/project");
    defer allocator.free(cache_path);
    var cache = uid_cache.loadFromFile(allocator, io, cache_path) catch return error.SkipZigTest;
    defer cache.deinit(allocator);

    const got = try resolveByUid(allocator, io, "test_fixtures/project", &cache, "uid://byhqeak2spha2");
    defer if (got) |path| allocator.free(path);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("res://ui/button/button.tscn", got.?);
}

test "resolveByUid rejects an unknown uid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cache_path = try uid_cache.defaultCachePath(allocator, "test_fixtures/project");
    defer allocator.free(cache_path);
    var cache = uid_cache.loadFromFile(allocator, io, cache_path) catch return error.SkipZigTest;
    defer cache.deinit(allocator);

    const got = try resolveByUid(allocator, io, "test_fixtures/project", &cache, "uid://doesnotexist9");
    defer if (got) |path| allocator.free(path);
    try std.testing.expect(got == null);
}

/// `mkdir -p`, which `std.Io.Dir` does not offer directly in 0.16.
fn makePath(io: std.Io, path: []const u8) !void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (len != 0) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..segment.len], segment);
        len += segment.len;
        // Already-exists is the expected outcome for every parent level.
        std.Io.Dir.cwd().createDir(io, buf[0..len], .default_dir) catch {};
    }
}

/// Build a throwaway project on disk: one scene carrying `uid`, and a JSON
/// manifest pointing at `manifest_scene`. Returns the project root.
fn writeTempProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    scene_rel: []const u8,
    manifest_scene: []const u8,
    uid: []const u8,
) ![]const u8 {
    const io_util = @import("../io_util.zig");
    const root = try std.fmt.allocPrint(allocator, "zig-out/test-relink-{s}", .{name});
    errdefer allocator.free(root);

    std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const scene_path = try std.fs.path.join(allocator, &.{ root, scene_rel });
    defer allocator.free(scene_path);
    if (std.fs.path.dirname(scene_path)) |dir| try makePath(io, dir);

    const project_file = try std.fs.path.join(allocator, &.{ root, "project.godot" });
    defer allocator.free(project_file);
    try io_util.writeFileAtomic(io, project_file, "config_version=5\n\n[application]\n\nconfig/name=\"Relink\"\n");

    const scene_text = try std.fmt.allocPrint(
        allocator,
        "[gd_scene format=3 uid=\"{s}\"]\n\n[node name=\"Root\" type=\"Node2D\"]\n",
        .{uid},
    );
    defer allocator.free(scene_text);
    try io_util.writeFileAtomic(io, scene_path, scene_text);

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "widget.manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_text = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "catalog_format_version": 2,
        \\  "id": "ui/widget",
        \\  "scene": "{s}",
        \\  "scene_uid": "{s}",
        \\  "tags": ["ui"],
        \\  "summary": "Prose that must survive relinking",
        \\  "when_to_use": "Whenever",
        \\  "signals": []
        \\}}
        \\
    ,
        .{ manifest_scene, uid },
    );
    defer allocator.free(manifest_text);
    try io_util.writeFileAtomic(io, manifest_path, manifest_text);

    return root;
}

test "relink repoints a manifest at the uid's current path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uid = "uid://byhqeak2spha2";

    // The scene lives at widgets/, the manifest still says ui/ — a move that
    // has already happened.
    const root = try writeTempProject(
        allocator,
        io,
        "moved",
        "widgets/widget.tscn",
        "res://ui/widget.tscn",
        uid,
    );
    defer allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // A uid cache that has caught up with the move, as Godot would write.
    var cache: uid_cache.Cache = .{ .entries = .empty };
    defer cache.entries.deinit(allocator);
    try cache.entries.append(allocator, .{
        .id = resource_uid.textToId(uid),
        .path = "res://widgets/widget.tscn",
    });

    var result = try relinkProject(allocator, io, root, &cache, false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.relinked);
    try std.testing.expectEqual(@as(usize, 0), result.unresolved);
    try std.testing.expect(!result.hasUnrepaired());
    try std.testing.expectEqual(Status.relinked, result.entries[0].status);
    try std.testing.expectEqualStrings("res://widgets/widget.tscn", result.entries[0].new_scene);

    // The rewritten manifest keeps its id and prose.
    var rescan = try catalog_scan.scanProject(allocator, io, root, &cache);
    defer rescan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rescan.entries.len);
    const entry = &rescan.entries[0];
    try std.testing.expect(entry.valid);
    try std.testing.expectEqualStrings("ui/widget", entry.id);
    try std.testing.expectEqualStrings("res://widgets/widget.tscn", entry.scene);
    try std.testing.expectEqualStrings("Prose that must survive relinking", entry.summary);
}

test "relink leaves the manifest alone on a dry run" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uid = "uid://byhqeak2spha2";

    const root = try writeTempProject(allocator, io, "dryrun", "widgets/widget.tscn", "res://ui/widget.tscn", uid);
    defer allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var cache: uid_cache.Cache = .{ .entries = .empty };
    defer cache.entries.deinit(allocator);
    try cache.entries.append(allocator, .{
        .id = resource_uid.textToId(uid),
        .path = "res://widgets/widget.tscn",
    });

    var result = try relinkProject(allocator, io, root, &cache, true);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.relinked);

    var rescan = try catalog_scan.scanProject(allocator, io, root, &cache);
    defer rescan.deinit(allocator);
    try std.testing.expectEqualStrings("res://ui/widget.tscn", rescan.entries[0].scene);
    try std.testing.expect(!rescan.entries[0].valid);
}

test "relink refuses to guess when the uid cache is stale" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uid = "uid://byhqeak2spha2";

    const root = try writeTempProject(allocator, io, "stale", "widgets/widget.tscn", "res://ui/widget.tscn", uid);
    defer allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Cache still names the pre-move path, which no longer exists.
    var cache: uid_cache.Cache = .{ .entries = .empty };
    defer cache.entries.deinit(allocator);
    try cache.entries.append(allocator, .{
        .id = resource_uid.textToId(uid),
        .path = "res://ui/widget.tscn",
    });

    var result = try relinkProject(allocator, io, root, &cache, false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.relinked);
    try std.testing.expectEqual(@as(usize, 1), result.unresolved);
    try std.testing.expect(result.hasUnrepaired());
    try std.testing.expectEqual(Status.unresolved, result.entries[0].status);
}

test "relink reports ok when nothing has moved" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try relinkProject(allocator, io, "test_fixtures/project", null, true);
    defer result.deinit(allocator);

    try std.testing.expect(result.checked > 0);
    try std.testing.expectEqual(@as(usize, 0), result.relinked);
    try std.testing.expect(!result.hasUnrepaired());
    for (result.entries) |entry| {
        try std.testing.expectEqual(Status.ok, entry.status);
    }
}
