//! Finds references to files that are not in the project.
//!
//! Godot reports a missing file only when something loads it: a scene the
//! game reaches late, or a `load()` behind a menu, stays quiet until a player
//! gets there. This reads the references instead, so the whole project is
//! covered without starting the engine.
//!
//! It is built to stay cheap on a large project. A scene's `ext_resource`
//! lines sit at the top of the file, before any embedded data, so only the
//! head of each scene is read; and each path is looked up on disk once, however
//! many files name it.

const std = @import("std");
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");

pub const Severity = enum { err, warning };

pub const Issue = struct {
    severity: Severity,
    /// `missing_file` throughout; a field so the rows read like `scene validate`'s.
    kind: []const u8,
    /// The file holding the reference, relative to the project root.
    file: []const u8,
    line: usize,
    /// The `res://` path that is not there.
    target: []const u8,
    /// Where the file seems to have gone: the file that now carries the
    /// reference's uid, or failing that the only file of the same name.
    found_at: ?[]const u8 = null,
    found_by: ?[]const u8 = null,
    message: []const u8,
};

pub const Report = struct {
    issues: std.ArrayList(Issue) = .empty,
    scenes: usize = 0,
    scripts: usize = 0,
    /// References looked at, repeats included.
    references: usize = 0,
    /// Distinct paths looked up on disk.
    lookups: usize = 0,

    pub fn errorCount(self: *const Report) usize {
        var n: usize = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == .err) n += 1;
        }
        return n;
    }
};

/// How much of a scene or resource is read looking for `ext_resource` lines.
/// They come first in the file, and one is under 200 bytes, so this covers
/// hundreds of them; a file with more is read in full.
const head_len = 64 * 1024;

const Checker = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache: ?uid_cache.Cache,
    seen: std.StringHashMap(bool),
    /// One buffer for the head of every scene, and an arena emptied after
    /// each file for anything read in full. Kept in the caller's arena, a
    /// 64 KiB head per scene came to 400 MB on a project of 6,000 scenes.
    head: []u8,
    scratch: std.heap.ArenaAllocator,
    /// Built on the first missing file, so a healthy project never pays for it.
    index: ?Index = null,
    report: Report = .{},

    fn exists(self: *Checker, res_path: []const u8) !bool {
        if (self.seen.get(res_path)) |known| return known;
        const fs_path = (try project_config.resPathToFilesystem(self.arena, self.root, res_path)) orelse return true;
        const found = if (std.Io.Dir.cwd().access(self.io, fs_path, .{})) |_| true else |_| false;
        try self.seen.put(try self.arena.dupe(u8, res_path), found);
        self.report.lookups += 1;
        return found;
    }

    fn add(self: *Checker, severity: Severity, file: []const u8, line: usize, target: []const u8, comptime fmt: []const u8, args: anytype) !void {
        return self.addFound(severity, file, line, target, null, fmt, args);
    }

    /// As `add`, and says where the file went when the project shows it.
    fn addFound(self: *Checker, severity: Severity, file: []const u8, line: usize, target: []const u8, uid_text: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
        var message = try std.fmt.allocPrint(self.arena, fmt, args);
        var found_at: ?[]const u8 = null;
        var found_by: ?[]const u8 = null;
        if (self.index == null) self.index = try Index.build(self);
        const index = &self.index.?;
        if (uid_text) |uid| {
            if (index.by_uid.get(uid)) |path| {
                found_at = path;
                found_by = "uid";
                message = try std.fmt.allocPrint(self.arena, "{s}; the file with this reference's uid is now {s}", .{ message, path });
            }
        }
        if (found_at == null) {
            const name = target[if (std.mem.lastIndexOfScalar(u8, target, '/')) |slash| slash + 1 else 0..];
            if (index.by_name.get(name)) |path| {
                // An empty path marks a name that more than one file has.
                if (path.len != 0) {
                    found_at = path;
                    found_by = "name";
                    message = try std.fmt.allocPrint(self.arena, "{s}; the only file of that name is {s}", .{ message, path });
                }
            }
        }
        try self.report.issues.append(self.arena, .{
            .severity = severity,
            .kind = "missing_file",
            .file = try self.arena.dupe(u8, file),
            .line = line,
            .target = try self.arena.dupe(u8, target),
            .found_at = found_at,
            .found_by = found_by,
            .message = message,
        });
    }
};

/// Every file in the project by name and by uid, for saying where a missing
/// file went. A uid is the sure sign: a renamed file keeps it, in its `.uid`
/// or `.import` sidecar or in its own header.
const Index = struct {
    by_uid: std.StringHashMap([]const u8),
    by_name: std.StringHashMap([]const u8),

    fn build(checker: *Checker) !Index {
        var index: Index = .{
            .by_uid = std.StringHashMap([]const u8).init(checker.arena),
            .by_name = std.StringHashMap([]const u8).init(checker.arena),
        };
        try index.walk(checker, "");
        return index;
    }

    fn walk(self: *Index, checker: *Checker, rel_dir: []const u8) !void {
        const arena = checker.arena;
        const dir_path = if (rel_dir.len == 0) checker.root else try std.fs.path.join(arena, &.{ checker.root, rel_dir });
        var dir = std.Io.Dir.cwd().openDir(checker.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(checker.io);
        var names: std.ArrayList([]const u8) = .empty;
        var dirs: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(checker.io) catch return) orelse break;
            if (std.mem.eql(u8, entry.name, ".gdignore")) return;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            switch (entry.kind) {
                .directory => try dirs.append(arena, try arena.dupe(u8, entry.name)),
                .file => try names.append(arena, try arena.dupe(u8, entry.name)),
                else => {},
            }
        }
        for (names.items) |name| {
            const rel = try joinRel(arena, rel_dir, name);
            const sidecar = std.mem.endsWith(u8, name, ".uid") or std.mem.endsWith(u8, name, ".import");
            if (!sidecar) {
                const res = try std.mem.concat(arena, u8, &.{ "res://", rel });
                const gop = try self.by_name.getOrPut(name);
                gop.value_ptr.* = if (gop.found_existing) "" else res;
                if (!isSceneName(name)) continue;
            }
            // The uid is in the first few hundred bytes of all three.
            const fs_path = try std.fs.path.join(arena, &.{ checker.root, rel });
            const file = std.Io.Dir.cwd().openFile(checker.io, fs_path, .{}) catch continue;
            defer file.close(checker.io);
            var buffer: [1024]u8 = undefined;
            const got = file.readPositionalAll(checker.io, &buffer, 0) catch continue;
            const at = std.mem.indexOf(u8, buffer[0..got], "uid://") orelse continue;
            var end = at;
            while (end < got and (std.ascii.isAlphanumeric(buffer[end]) or buffer[end] == ':' or buffer[end] == '/')) end += 1;
            const owner = if (std.mem.endsWith(u8, name, ".uid")) rel[0 .. rel.len - ".uid".len] else if (std.mem.endsWith(u8, name, ".import")) rel[0 .. rel.len - ".import".len] else rel;
            try self.by_uid.put(try arena.dupe(u8, buffer[at..end]), try std.mem.concat(arena, u8, &.{ "res://", owner }));
        }
        for (dirs.items) |name| try self.walk(checker, try joinRel(arena, rel_dir, name));
    }
};

/// Everything is allocated in `arena` and nothing is freed, so pass an arena.
pub fn check(arena: std.mem.Allocator, io: std.Io, project_root: []const u8) !Report {
    var checker: Checker = .{
        .arena = arena,
        .io = io,
        .root = project_root,
        .cache = null,
        .seen = std.StringHashMap(bool).init(arena),
        .head = try arena.alloc(u8, head_len),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer checker.scratch.deinit();
    const cache_path = try uid_cache.defaultCachePath(arena, project_root);
    checker.cache = uid_cache.loadFromFile(arena, io, cache_path) catch null;

    try checkProjectFile(&checker);
    try walk(&checker, "");
    return checker.report;
}

fn checkProjectFile(checker: *Checker) !void {
    const path = try std.fs.path.join(checker.arena, &.{ checker.root, "project.godot" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(checker.io, path, checker.arena, .unlimited) catch return;
    var section: []const u8 = "";
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        var rest = line[eq + 1 ..];
        // Every quoted res:// path in the value: a plain string, an autoload's
        // "*res://", or the entries of a PackedStringArray.
        while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse break;
            var text = rest[open + 1 .. close];
            rest = rest[close + 1 ..];
            if (std.mem.startsWith(u8, text, "*")) text = text[1..];
            if (!std.mem.startsWith(u8, text, "res://")) continue;
            checker.report.references += 1;
            if (try checker.exists(text)) continue;
            if (try madeByImport(checker, text)) continue;
            // The game does not start without its main scene, and a script
            // that names a missing autoload does not compile. A missing icon
            // or translation is logged and the game carries on.
            // run/main_scene.mobile and the like are the main scene on that platform.
            const main_scene = std.mem.eql(u8, section, "application") and
                (std.mem.eql(u8, key, "run/main_scene") or std.mem.startsWith(u8, key, "run/main_scene."));
            const autoload = std.mem.eql(u8, section, "autoload");
            if (main_scene) {
                try checker.add(.err, "project.godot", line_no, text, "the main scene {s} does not exist, so the game cannot start", .{text});
            } else if (autoload) {
                try checker.add(.err, "project.godot", line_no, text, "autoload {s} points at {s}, which does not exist; Godot logs an error at start and every script that names {s} fails", .{ key, text, key });
            } else {
                try checker.add(.warning, "project.godot", line_no, text, "[{s}] {s} names {s}, which does not exist", .{ section, key, text });
            }
        }
    }
}

/// `text.en.translation` is written by Godot when it imports `text.csv`, and
/// is usually left out of version control, so a fresh checkout lacks it until
/// the first import. With the CSV there, it is not missing. Godot's own
/// translation demo was reported for exactly this.
fn madeByImport(checker: *Checker, res_path: []const u8) !bool {
    const suffix = ".translation";
    if (!std.mem.endsWith(u8, res_path, suffix)) return false;
    const stem = res_path[0 .. res_path.len - suffix.len];
    const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return false;
    const csv = try std.mem.concat(checker.arena, u8, &.{ stem[0..dot], ".csv" });
    return checker.exists(csv);
}

fn walk(checker: *Checker, rel_dir: []const u8) !void {
    const dir_path = if (rel_dir.len == 0) checker.root else try std.fs.path.join(checker.arena, &.{ checker.root, rel_dir });
    var dir = std.Io.Dir.cwd().openDir(checker.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(checker.io);

    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(checker.io) catch return) orelse break;
        // Godot neither imports nor loads from a folder holding .gdignore.
        if (std.mem.eql(u8, entry.name, ".gdignore")) return;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => try dirs.append(checker.arena, try checker.arena.dupe(u8, entry.name)),
            .file => {
                if (isSceneName(entry.name) or std.mem.endsWith(u8, entry.name, ".gd")) {
                    try files.append(checker.arena, try checker.arena.dupe(u8, entry.name));
                }
            },
            else => {},
        }
    }
    // Directory order differs between filesystems; sorted, the report does not.
    std.mem.sort([]const u8, files.items, {}, lessThan);
    std.mem.sort([]const u8, dirs.items, {}, lessThan);

    for (files.items) |name| {
        defer _ = checker.scratch.reset(.retain_capacity);
        const scratch = checker.scratch.allocator();
        // `rel` outlives the file only when an issue names it, and add() copies it then.
        const rel = try joinRel(scratch, rel_dir, name);
        const fs_path = try std.fs.path.join(scratch, &.{ checker.root, rel });
        if (isSceneName(name)) {
            checker.report.scenes += 1;
            const head = readHead(checker, fs_path) orelse continue;
            try checkSceneText(checker, rel, head);
        } else {
            checker.report.scripts += 1;
            const source = std.Io.Dir.cwd().readFileAlloc(checker.io, fs_path, scratch, .unlimited) catch continue;
            try checkScriptText(checker, rel, source);
        }
    }
    for (dirs.items) |name| try walk(checker, try joinRel(checker.arena, rel_dir, name));
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn isSceneName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".tscn") or std.mem.endsWith(u8, name, ".tres");
}

fn joinRel(arena: std.mem.Allocator, rel_dir: []const u8, name: []const u8) ![]const u8 {
    if (rel_dir.len == 0) return name;
    return std.mem.concat(arena, u8, &.{ rel_dir, "/", name });
}

/// The part of a scene that can hold `ext_resource` lines: the first
/// `head_len` bytes, or the whole file when those end before the first
/// section that is not one.
fn readHead(checker: *Checker, fs_path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(checker.io, fs_path, .{}) catch return null;
    defer file.close(checker.io);
    const buffer = checker.head;
    const got = file.readPositionalAll(checker.io, buffer, 0) catch return null;
    if (got < head_len or extResourcesEnd(buffer[0..got])) return buffer[0..got];
    return std.Io.Dir.cwd().readFileAlloc(checker.io, fs_path, checker.scratch.allocator(), .unlimited) catch null;
}

/// Whether `text` reaches a section after the `ext_resource` ones, which are
/// always first: Godot refuses a file with one further down.
fn extResourcesEnd(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (isLaterSection(line)) return true;
    }
    return false;
}

fn isLaterSection(line: []const u8) bool {
    if (line.len == 0 or line[0] != '[') return false;
    return !(std.mem.startsWith(u8, line, "[ext_resource") or
        std.mem.startsWith(u8, line, "[gd_scene") or
        std.mem.startsWith(u8, line, "[gd_resource"));
}

fn attribute(line: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = " " ++ name ++ "=\"";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

fn checkSceneText(checker: *Checker, rel: []const u8, text: []const u8) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (isLaterSection(line)) return;
        if (!std.mem.startsWith(u8, line, "[ext_resource")) continue;
        const path = attribute(line, "path") orelse continue;
        if (!std.mem.startsWith(u8, path, "res://")) continue;
        checker.report.references += 1;
        const uid = attribute(line, "uid");
        if (try checker.exists(path)) {
            // The file is there, but Godot follows the uid before the path,
            // and the cache still sends this uid to a file that is gone: what
            // a rename by hand leaves behind until the next import.
            if (try staleCachePath(checker, uid, path)) |old| {
                try checker.report.issues.append(checker.arena, .{
                    .severity = .err,
                    .kind = "uid_path_mismatch",
                    .file = try checker.arena.dupe(u8, rel),
                    .line = line_no,
                    .target = old,
                    .message = try std.fmt.allocPrint(checker.arena, "{s} is there, but the project's uid cache still maps this reference's uid to {s}, which is gone, and Godot follows the uid first; project import rewrites the cache (project run imports before it runs)", .{ path, old }),
                });
            }
            continue;
        }
        // Godot loads by uid first and only falls back to the path, so a
        // reference whose uid still finds a file loads, stale path and all.
        if (try resolvesByUid(checker, uid, path)) continue;
        try checker.addFound(.err, rel, line_no, path, uid, "{s} does not exist, so Godot fails to load {s}", .{ path, rel });
    }
}

fn resolvesByUid(checker: *Checker, uid_text: ?[]const u8, path: []const u8) !bool {
    const cache = checker.cache orelse return false;
    const text = uid_text orelse return false;
    const elsewhere = cache.pathForId(resource_uid.textToId(text)) orelse return false;
    if (std.mem.eql(u8, elsewhere, path)) return false;
    return checker.exists(elsewhere);
}

/// The path the uid cache gives for `uid_text` when it is not `path` and is
/// not on disk either.
fn staleCachePath(checker: *Checker, uid_text: ?[]const u8, path: []const u8) !?[]const u8 {
    const cache = checker.cache orelse return null;
    const text = uid_text orelse return null;
    const cached = cache.pathForId(resource_uid.textToId(text)) orelse return null;
    if (std.mem.eql(u8, cached, path)) return null;
    if (try checker.exists(cached)) return null;
    return try checker.arena.dupe(u8, cached);
}

const Call = enum { preload, load, extends };

fn checkScriptText(checker: *Checker, rel: []const u8, source: []const u8) !void {
    const script_dir = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |slash| rel[0..slash] else "";
    var line_no: usize = 0;
    var in_block_string = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        var i: usize = 0;
        while (i < line.len) {
            if (in_block_string) {
                const close = std.mem.indexOfPos(u8, line, i, "\"\"\"") orelse break;
                in_block_string = false;
                i = close + 3;
                continue;
            }
            const c = line[i];
            if (c == '#') break;
            if (std.mem.startsWith(u8, line[i..], "\"\"\"")) {
                in_block_string = true;
                i += 3;
                continue;
            }
            if (c == '"' or c == '\'') {
                i = endOfString(line, i);
                continue;
            }
            if (callAt(line, i)) |found| {
                const literal = stringAt(line, found.arg);
                if (literal) |value| {
                    try checkScriptPath(checker, rel, script_dir, line_no, found.call, value.text);
                    i = value.end;
                    continue;
                }
                i = found.arg;
                continue;
            }
            i += 1;
        }
    }
}

/// The index just past the string that opens at `start`.
fn endOfString(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `preload(`, `load(` or a leading `extends` at `i`, with `arg` the index
/// where its argument starts.
fn callAt(line: []const u8, i: usize) ?struct { call: Call, arg: usize } {
    if (i > 0 and isIdentChar(line[i - 1])) return null;
    const rest = line[i..];
    if (std.mem.startsWith(u8, rest, "preload(")) return .{ .call = .preload, .arg = i + "preload(".len };
    if (std.mem.startsWith(u8, rest, "load(")) return .{ .call = .load, .arg = i + "load(".len };
    if (std.mem.startsWith(u8, rest, "extends ") and std.mem.trim(u8, line[0..i], " \t").len == 0) {
        return .{ .call = .extends, .arg = i + "extends ".len };
    }
    return null;
}

/// A string literal starting at or after `start`, past any spaces.
fn stringAt(line: []const u8, start: usize) ?struct { text: []const u8, end: usize } {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or (line[i] != '"' and line[i] != '\'')) return null;
    const end = endOfString(line, i);
    if (end <= i + 1 or line[end - 1] != line[i]) return null;
    return .{ .text = line[i + 1 .. end - 1], .end = end };
}

fn checkScriptPath(checker: *Checker, rel: []const u8, script_dir: []const u8, line_no: usize, call: Call, text: []const u8) !void {
    var target: []const u8 = text;
    if (std.mem.indexOf(u8, text, "://") == null) {
        // preload and extends take a path beside the script as well. What a
        // bare path means to load() depends on the caller, so it is left alone.
        if (call == .load or text.len == 0 or std.mem.indexOfScalar(u8, text, '.') == null) return;
        const scratch = checker.scratch.allocator();
        const local = if (script_dir.len == 0) text else try std.mem.concat(scratch, u8, &.{ script_dir, "/", text });
        target = try std.mem.concat(scratch, u8, &.{ "res://", local });
    } else if (!std.mem.startsWith(u8, text, "res://")) return;
    // A path built at run time, such as "res://levels/%d.tscn" % n.
    if (std.mem.indexOfAny(u8, target, "%{") != null) return;

    checker.report.references += 1;
    if (try checker.exists(target)) return;
    switch (call) {
        .preload => try checker.add(.err, rel, line_no, target, "preload of {s}, which does not exist: a parse error, so {s} does not load at all", .{ target, rel }),
        .extends => try checker.add(.err, rel, line_no, target, "extends {s}, which does not exist: a parse error, so {s} does not load at all", .{ target, rel }),
        // A load() may be guarded, or name a file the game writes; Godot
        // only complains when the line runs.
        .load => try checker.add(.warning, rel, line_no, target, "load of {s}, which does not exist; it fails when this line runs", .{target}),
    }
}

fn testChecker(arena: std.mem.Allocator, root: []const u8) Checker {
    return .{
        .arena = arena,
        .io = std.testing.io,
        .root = root,
        .cache = null,
        .seen = std.StringHashMap(bool).init(arena),
        .head = &.{},
        // Backed by the test's arena, which frees it.
        .scratch = std.heap.ArenaAllocator.init(arena),
    };
}

test "a scene's missing ext_resource is an error, and a present one is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var checker = testChecker(arena_state.allocator(), "test_fixtures/missing_files");
    try checkSceneText(&checker, "main.tscn",
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://scripts/here.gd" id="1_a"]
        \\[ext_resource type="Texture2D" path="res://art/gone.png" id="2_b"]
        \\
        \\[node name="Main" type="Node2D"]
        \\script = ExtResource("1_a")
        \\[ext_resource type="Texture2D" path="res://art/never_read.png" id="3_c"]
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), checker.report.issues.items.len);
    const issue = checker.report.issues.items[0];
    try std.testing.expectEqual(Severity.err, issue.severity);
    try std.testing.expectEqualStrings("res://art/gone.png", issue.target);
    try std.testing.expectEqual(@as(usize, 4), issue.line);
}

test "preload and extends of a missing file are errors, load a warning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var checker = testChecker(arena_state.allocator(), "test_fixtures/missing_files");
    try checkScriptText(&checker, "scripts/game.gd",
        \\extends "res://scripts/gone_base.gd"
        \\const A := preload("res://scripts/here.gd")
        \\const B := preload("res://scripts/gone.gd")
        \\const C := preload("here.gd")
        \\const D := preload("gone_beside.gd")
        \\# preload("res://scripts/in_a_comment.gd")
        \\var text := "preload(\"res://scripts/in_a_string.gd\")"
        \\func _ready() -> void:
        \\    var s = load("res://scripts/gone_late.gd")
        \\    var level = load("res://levels/%d.tscn" % 3)
        \\    var save = ConfigFile.new().load("user://save.cfg")
        \\    reload("res://scripts/not_a_load.gd")
        \\
    );
    const issues = checker.report.issues.items;
    try std.testing.expectEqual(@as(usize, 4), issues.len);
    try std.testing.expectEqualStrings("res://scripts/gone_base.gd", issues[0].target);
    try std.testing.expectEqual(Severity.err, issues[0].severity);
    try std.testing.expectEqualStrings("res://scripts/gone.gd", issues[1].target);
    try std.testing.expectEqualStrings("res://scripts/gone_beside.gd", issues[2].target);
    try std.testing.expectEqual(Severity.err, issues[2].severity);
    try std.testing.expectEqualStrings("res://scripts/gone_late.gd", issues[3].target);
    try std.testing.expectEqual(Severity.warning, issues[3].severity);
    try std.testing.expectEqual(@as(usize, 9), issues[3].line);
}

test "the whole fixture project: project.godot, scenes and scripts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try check(arena_state.allocator(), std.testing.io, "test_fixtures/missing_files");
    // main scene present; one autoload gone (error) and the icon gone
    // (warning) in project.godot; one texture gone in main.tscn. The scene
    // under ignored/ names a missing file and is never read.
    try std.testing.expectEqual(@as(usize, 3), report.issues.items.len);
    try std.testing.expectEqual(@as(usize, 2), report.errorCount());
    try std.testing.expectEqualStrings("project.godot", report.issues.items[0].file);
    try std.testing.expectEqualStrings("main.tscn", report.issues.items[2].file);
    try std.testing.expectEqual(@as(usize, 1), report.scenes);
    try std.testing.expectEqual(@as(usize, 2), report.scripts);
}

test "a missing file is traced to where it went, by uid and then by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var checker = testChecker(arena_state.allocator(), "test_fixtures/missing_files");
    try checkSceneText(&checker, "main.tscn",
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" uid="uid://c1moved0script" path="res://old/renamed.gd" id="1_a"]
        \\[ext_resource type="Script" path="res://old/here.gd" id="2_b"]
        \\[ext_resource type="Script" path="res://old/nowhere.gd" id="3_c"]
        \\
    );
    const issues = checker.report.issues.items;
    try std.testing.expectEqual(@as(usize, 3), issues.len);
    try std.testing.expectEqualStrings("res://scripts/moved.gd", issues[0].found_at.?);
    try std.testing.expectEqualStrings("uid", issues[0].found_by.?);
    try std.testing.expectEqualStrings("res://scripts/here.gd", issues[1].found_at.?);
    try std.testing.expectEqualStrings("name", issues[1].found_by.?);
    try std.testing.expect(issues[2].found_at == null);
}

test "a translation Godot makes from a CSV is not missing while the CSV is there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var checker = testChecker(arena_state.allocator(), "test_fixtures/missing_files");
    try std.testing.expect(try madeByImport(&checker, "res://text/words.en.translation"));
    try std.testing.expect(!try madeByImport(&checker, "res://text/other.en.translation"));
    try std.testing.expect(!try madeByImport(&checker, "res://text/words.csv"));
}

test "ext_resource lines past the head of a large file are still read" {
    try std.testing.expect(extResourcesEnd("[gd_scene format=3]\n[ext_resource path=\"res://a\" id=\"1\"]\n\n[node name=\"A\"]\n"));
    try std.testing.expect(!extResourcesEnd("[gd_scene format=3]\n[ext_resource path=\"res://a\" id=\"1\"]\n[ext_resource path=\"res"));
}
