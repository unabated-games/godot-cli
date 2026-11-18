//! Move or rename a project file and repoint everything that referenced it.
//!
//! Godot tracks files by UID, so the editor repairs references when a file is
//! moved inside it. Outside the editor a plain `mv` leaves every `res://` path
//! in every scene, resource, manifest, and `project.godot` setting stale. This
//! does the `mv` and the repointing together.

const std = @import("std");
const error_details = @import("error_details.zig");
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
    /// project.godot will not parse, so it could not be kept in step.
    InvalidFormat,
};

pub const Result = struct {
    from: []const u8,
    to: []const u8,
    sidecars_moved: usize,
    files_changed: usize,
    references_retargeted: usize,
    /// ext_resource ids re-seeded from the new file name (--rename-ids).
    ids_renamed: usize = 0,
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
    return try allocator.print("res://{s}", .{rel});
}

/// After the path is retargeted, an id seeded from the old file's name still
/// names it (`Script_player` pointing at `hero.gd`). Re-seed it from the new
/// name so a diff reads the way the move did. Best effort: a name already in
/// use is left alone, since the id is arbitrary and correctness comes first.
fn renameIdsForMovedFile(allocator: std.mem.Allocator, doc: *document.Document, to_path: []const u8) !usize {
    const basename = std.fs.path.basename(to_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;

    var renamed: usize = 0;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const path = section.header.getString("path") orelse continue;
        if (!std.mem.eql(u8, path, to_path)) continue;
        const old_id = section.header.getString("id") orelse continue;
        const res_type = section.header.getString("type") orelse continue;
        // Only ids of godot-cli's own `{Type}_{hint}` shape are re-seeded;
        // Godot's `1_ab12c` form names no file and needs no rename.
        if (!std.mem.startsWith(u8, old_id, res_type)) continue;
        const new_id = try allocator.print("{s}_{s}", .{ res_type, stem });
        defer allocator.free(new_id);
        if (try text_batch.renameExtResourceId(doc, allocator, old_id, new_id)) |_| renamed += 1;
    }
    return renamed;
}

pub const Pair = struct { from: []const u8, to: []const u8 };

/// The file moves a `project move` asks for, every one checked before any
/// happens, so a bad destination cannot leave half a folder moved:
/// - one `from` that is a folder: every file in it moves to the same place
///   under `to`, which must not exist (a folder rename);
/// - several `from`s, or a `to` ending in `/`: each file moves into the
///   folder `to`, keeping its name;
/// - otherwise one file to one path.
/// A `.uid` or `.import` file whose file is moving is left out: it goes with
/// its file. Trial 47 spent six calls on six files.
pub fn planMoves(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, froms: []const []const u8, to_in: []const u8) Error![]Pair {
    var pairs: std.ArrayList(Pair) = .empty;
    const into_folder = froms.len > 1 or std.mem.endsWith(u8, to_in, "/");
    const to_base = try normalizeResPath(allocator, project_root, std.mem.trimEnd(u8, to_in, "/"));
    if (into_folder) {
        const to_fs = (project_config.resPathToFilesystem(allocator, project_root, to_base) catch return error.InvalidPath) orelse return error.InvalidPath;
        if (std.Io.Dir.cwd().statFile(io, to_fs, .{})) |stat| {
            if (stat.kind != .directory) {
                error_details.record(.{ .field = "to", .value = to_in, .hint = "with several --from, or a --to ending in /, --to is the folder the files go into, and this is a file; nothing was moved" });
                return error.DestinationExists;
            }
        } else |_| {}
    }
    for (froms) |from_in| {
        const from = try normalizeResPath(allocator, project_root, std.mem.trimEnd(u8, from_in, "/"));
        const from_fs = (project_config.resPathToFilesystem(allocator, project_root, from) catch return error.InvalidPath) orelse return error.InvalidPath;
        const stat = std.Io.Dir.cwd().statFile(io, from_fs, .{}) catch return error.SourceNotFound;
        if (stat.kind == .directory) {
            if (into_folder) {
                error_details.record(.{ .field = "from", .value = from_in, .hint = "a folder moves on its own: --from res://ui --to res://interface renames it. Several --from, or a --to ending in /, move files into a folder" });
                return error.InvalidPath;
            }
            var dir = std.Io.Dir.cwd().openDir(io, from_fs, .{ .iterate = true }) catch return error.Io;
            defer dir.close(io);
            var walker = dir.walk(allocator) catch return error.OutOfMemory;
            defer walker.deinit();
            var files: std.ArrayList([]const u8) = .empty;
            while (walker.next(io) catch return error.Io) |entry| {
                if (entry.kind != .file) continue;
                try files.append(allocator, try allocator.dupe(u8, entry.path));
            }
            for (files.items) |rel| {
                if (isSidecarOf(rel, files.items)) continue;
                const rel_res = try std.mem.replaceOwned(u8, allocator, rel, "\\", "/");
                try pairs.append(allocator, .{
                    .from = try allocator.print("{s}/{s}", .{ from, rel_res }),
                    .to = try allocator.print("{s}/{s}", .{ to_base, rel_res }),
                });
            }
        } else {
            const to = if (into_folder) try allocator.print("{s}/{s}", .{ to_base, std.fs.path.basename(from) }) else to_base;
            try pairs.append(allocator, .{ .from = from, .to = to });
        }
    }
    for (pairs.items, 0..) |pair, i| {
        const to_fs = (project_config.resPathToFilesystem(allocator, project_root, pair.to) catch return error.InvalidPath) orelse return error.InvalidPath;
        if (std.Io.Dir.cwd().access(io, to_fs, .{})) |_| {
            error_details.record(.{ .field = "to", .value = pair.to, .hint = "a file is already there; nothing was moved" });
            return error.DestinationExists;
        } else |_| {}
        for (pairs.items[0..i]) |earlier| if (std.mem.eql(u8, earlier.to, pair.to)) {
            error_details.record(.{ .field = "to", .value = pair.to, .hint = "two of the files would land on the same path; nothing was moved" });
            return error.DestinationExists;
        };
    }
    return pairs.items;
}

/// `x.gd.uid` or `x.png.import` when `x.gd` or `x.png` is among `files`.
fn isSidecarOf(path: []const u8, files: []const []const u8) bool {
    for ([_][]const u8{ ".uid", ".import" }) |suffix| {
        if (!std.mem.endsWith(u8, path, suffix)) continue;
        const base = path[0 .. path.len - suffix.len];
        for (files) |candidate| if (std.mem.eql(u8, candidate, base)) return true;
    }
    return false;
}

/// Remove the folders a folder move emptied, deepest first; one still
/// holding anything (a file the move did not take) stays.
pub fn removeEmptyFolders(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, folder_res: []const u8) void {
    const fs_path = (project_config.resPathToFilesystem(allocator, project_root, folder_res) catch return) orelse return;
    var dir = std.Io.Dir.cwd().openDir(io, fs_path, .{ .iterate = true }) catch return;
    var walker = dir.walk(allocator) catch {
        dir.close(io);
        return;
    };
    var folders: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) folders.append(allocator, allocator.dupe(u8, entry.path) catch return) catch return;
    }
    walker.deinit();
    dir.close(io);
    std.mem.sort([]const u8, folders.items, {}, struct {
        fn deeper(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.deeper);
    for (folders.items) |rel| {
        const full = std.fs.path.join(allocator, &.{ fs_path, rel }) catch return;
        std.Io.Dir.cwd().deleteDir(io, full) catch {};
    }
    std.Io.Dir.cwd().deleteDir(io, fs_path) catch {};
}

pub fn moveResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    from_in: []const u8,
    to_in: []const u8,
    dry_run: bool,
    rename_ids: bool,
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

    // project.godot is rewritten after the move, so a file that will not
    // parse has to stop the move before anything changes; otherwise a moved
    // main scene or autoload would be left pointing at the old path, with
    // settings_updated: 0 the only sign.
    {
        const project_file = try std.fs.path.join(allocator, &.{ project_root, "project.godot" });
        defer allocator.free(project_file);
        if (project_godot.readFile(allocator, io, project_file)) |loaded| {
            var probe = loaded;
            probe.deinit(allocator);
        } else |err| switch (err) {
            error.InvalidFormat => {
                error_details.record(.{
                    .field = "project.godot",
                    .value = try allocator.dupe(u8, project_file),
                    .hint = "godot-cli could not parse this project.godot, and a move has to keep its main scene and autoload paths in step, so nothing was moved",
                });
                return error.InvalidFormat;
            },
            else => {},
        }
    }

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
        const old_side = try allocator.print("{s}{s}", .{ from_fs, suffix });
        defer allocator.free(old_side);
        const new_side = try allocator.print("{s}{s}", .{ to_fs, suffix });
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
    var ids_renamed: usize = 0;
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
        if (rename_ids) ids_renamed += renameIdsForMovedFile(allocator, &doc, to) catch 0;
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
            const quoted_from = try allocator.print("\"{s}\"", .{from});
            defer allocator.free(quoted_from);
            const quoted_to = try allocator.print("\"{s}\"", .{to});
            defer allocator.free(quoted_to);
            const star_from = try allocator.print("\"*{s}\"", .{from});
            defer allocator.free(star_from);
            const star_to = try allocator.print("\"*{s}\"", .{to});
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
        .ids_renamed = ids_renamed,
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
