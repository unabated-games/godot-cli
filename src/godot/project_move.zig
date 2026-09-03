//! Move or rename a project file and repoint everything that referenced it.
//!
//! Godot tracks files by UID, so the editor repairs references when a file is
//! moved inside it. Outside the editor a plain `mv` leaves every `res://` path
//! in every scene, resource, manifest, and `project.godot` setting stale. This
//! does the `mv` and the repointing together.

const std = @import("std");
const document = @import("text_format/document.zig");
const writer = @import("text_format/writer.zig");
const text_batch = @import("text_format/batch.zig");
const project_config = @import("project_config.zig");
const project_godot = @import("project_godot.zig");
const catalog_add = @import("catalog_add.zig");

pub const Error = error{
    OutOfMemory,
    Io,
    InvalidPath,
    SourceNotFound,
    DestinationExists,
};

pub const Result = struct {
    from: []const u8,
    to: []const u8,
    sidecars_moved: usize,
    files_changed: usize,
    references_retargeted: usize,
    manifests_updated: usize,
    settings_updated: usize,
    changed_files: [][]const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.from);
        allocator.free(self.to);
        for (self.changed_files) |f| allocator.free(f);
        allocator.free(self.changed_files);
    }
};

/// Accept `res://x`, `x`, or `./x` relative to the project root.
pub fn normalizeResPath(allocator: std.mem.Allocator, project_root: []const u8, path: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, path, "res://")) return try allocator.dupe(u8, path);
    if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var rel: []const u8 = path;
    // Strip the project root only as a whole path component; with a root of
    // "." a bare prefix match would turn "../x" into "./x".
    if (!std.mem.eql(u8, project_root, ".") and rel.len > project_root.len and std.mem.startsWith(u8, rel, project_root) and rel[project_root.len] == '/') {
        rel = rel[project_root.len + 1 ..];
    }
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    while (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
    if (rel.len == 0 or std.mem.startsWith(u8, rel, "..")) return error.InvalidPath;
    return try std.fmt.allocPrint(allocator, "res://{s}", .{rel});
}

pub fn moveResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    from_in: []const u8,
    to_in: []const u8,
    dry_run: bool,
) Error!Result {
    const from = try normalizeResPath(allocator, project_root, from_in);
    errdefer allocator.free(from);
    const to = try normalizeResPath(allocator, project_root, to_in);
    errdefer allocator.free(to);

    const from_fs = (project_config.resPathToFilesystem(allocator, project_root, from) catch return error.InvalidPath) orelse return error.InvalidPath;
    defer allocator.free(from_fs);
    const to_fs = (project_config.resPathToFilesystem(allocator, project_root, to) catch return error.InvalidPath) orelse return error.InvalidPath;
    defer allocator.free(to_fs);

    std.Io.Dir.cwd().access(io, from_fs, .{}) catch return error.SourceNotFound;
    if (std.Io.Dir.cwd().access(io, to_fs, .{})) |_| return error.DestinationExists else |_| {}

    var changed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (changed.items) |f| allocator.free(f);
        changed.deinit(allocator);
    }

    var sidecars_moved: usize = 0;
    if (!dry_run) {
        if (std.fs.path.dirname(to_fs)) |parent| std.Io.Dir.cwd().createDirPath(io, parent) catch {};
        std.Io.Dir.cwd().rename(from_fs, std.Io.Dir.cwd(), to_fs, io) catch return error.Io;
    }
    // The UID sidecar and import metadata belong to the file and go with it.
    // Counted on a dry run too, so the preview matches the move.
    for ([_][]const u8{ ".uid", ".import" }) |suffix| {
        const old_side = try std.fmt.allocPrint(allocator, "{s}{s}", .{ from_fs, suffix });
        defer allocator.free(old_side);
        const new_side = try std.fmt.allocPrint(allocator, "{s}{s}", .{ to_fs, suffix });
        defer allocator.free(new_side);
        std.Io.Dir.cwd().access(io, old_side, .{}) catch continue;
        if (!dry_run) std.Io.Dir.cwd().rename(old_side, std.Io.Dir.cwd(), new_side, io) catch continue;
        sidecars_moved += 1;
    }

    // Every scene and resource that referenced the old path.
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    try collectFiles(allocator, io, project_root, &files);

    var files_changed: usize = 0;
    var references: usize = 0;
    var manifests_updated: usize = 0;
    for (files.items) |file_path| {
        if (std.mem.endsWith(u8, file_path, ".manifest.json")) {
            if (try manifestPointsAt(allocator, io, file_path, from)) {
                if (!dry_run) {
                    var updated = catalog_add.addManifest(allocator, io, project_root, .{
                        .scene = to,
                        .update = true,
                        .output = file_path,
                    }) catch return error.Io;
                    updated.deinit(allocator);
                }
                manifests_updated += 1;
                try changed.append(allocator, try allocator.dupe(u8, file_path));
            }
            continue;
        }
        var doc = document.parseFile(allocator, io, file_path) catch continue;
        defer doc.deinit(allocator);
        const count = text_batch.retargetExtResourcePaths(&doc, allocator, from, to) catch return error.OutOfMemory;
        if (count == 0) continue;
        if (!dry_run) writer.writeFile(allocator, file_path, &doc, null) catch return error.Io;
        files_changed += 1;
        references += count;
        try changed.append(allocator, try allocator.dupe(u8, file_path));
    }

    // project.godot values: main scene, autoloads (`*res://...`), any setting.
    var settings_updated: usize = 0;
    {
        const project_file = try std.fs.path.join(allocator, &.{ project_root, "project.godot" });
        defer allocator.free(project_file);
        if (project_godot.readFile(allocator, io, project_file)) |loaded| {
            var doc = loaded;
            defer doc.deinit(allocator);
            const quoted_from = try std.fmt.allocPrint(allocator, "\"{s}\"", .{from});
            defer allocator.free(quoted_from);
            const quoted_to = try std.fmt.allocPrint(allocator, "\"{s}\"", .{to});
            defer allocator.free(quoted_to);
            const star_from = try std.fmt.allocPrint(allocator, "\"*{s}\"", .{from});
            defer allocator.free(star_from);
            const star_to = try std.fmt.allocPrint(allocator, "\"*{s}\"", .{to});
            defer allocator.free(star_to);
            for (doc.sections.items) |*section| {
                for (section.entries.items) |entry| {
                    const replacement: ?[]const u8 = if (std.mem.eql(u8, entry.value, quoted_from)) quoted_to else if (std.mem.eql(u8, entry.value, star_from)) star_to else null;
                    if (replacement) |value| {
                        const key = try allocator.dupe(u8, entry.key);
                        defer allocator.free(key);
                        section.setEntry(allocator, key, value) catch return error.OutOfMemory;
                        settings_updated += 1;
                    }
                }
            }
            if (settings_updated > 0 and !dry_run) {
                project_godot.writeFile(allocator, io, project_file, &doc) catch return error.Io;
                try changed.append(allocator, try allocator.dupe(u8, project_file));
            }
        } else |_| {}
    }

    return .{
        .from = from,
        .to = to,
        .sidecars_moved = sidecars_moved,
        .files_changed = files_changed,
        .references_retargeted = references,
        .manifests_updated = manifests_updated,
        .settings_updated = settings_updated,
        .changed_files = try changed.toOwnedSlice(allocator),
    };
}

fn manifestPointsAt(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8, from: []const u8) Error!bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const scene = parsed.value.object.get("scene") orelse return false;
    return scene == .string and std.mem.eql(u8, scene.string, from);
}

/// `.tscn`, `.tres`, and `*.manifest.json` under the project, skipping `.godot/`
/// and dot-directories.
fn collectFiles(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.Io;
    defer dir.close(io);
    var it = dir.iterate();
    while (true) {
        const next = it.next(io) catch return error.Io;
        const entry = next orelse break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(child);
        switch (entry.kind) {
            .directory => {
                try collectFiles(allocator, io, child, out);
                allocator.free(child);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".tscn") or std.mem.endsWith(u8, entry.name, ".tres") or std.mem.endsWith(u8, entry.name, ".manifest.json")) {
                    try out.append(allocator, child);
                } else allocator.free(child);
            },
            else => allocator.free(child),
        }
    }
}

test "normalizeResPath accepts relative and res:// forms" {
    const allocator = std.testing.allocator;
    const a = try normalizeResPath(allocator, ".", "./scripts/hero.gd");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("res://scripts/hero.gd", a);
    const b = try normalizeResPath(allocator, "/proj", "res://x.tscn");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("res://x.tscn", b);
    try std.testing.expectError(error.InvalidPath, normalizeResPath(allocator, ".", "../outside.gd"));
}
