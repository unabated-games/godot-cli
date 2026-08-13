//! Discover and parse catalog manifests in a Godot project.
//!
//! Manifests are `*.manifest.json` — plain data, identified by filename, needing
//! nothing installed in the project to read or write. `catalog add` writes them
//! and an agent can author one directly.

const std = @import("std");
const document = @import("text_format/document.zig");
const property_line = @import("variant/property_line.zig");
const parse = @import("variant/parse.zig");
const Value = @import("variant/value.zig").Value;
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const io_util = @import("../io_util.zig");

/// Suffix identifying a manifest. Matched on the filename, so the scan rejects
/// candidates without reading them.
pub const manifest_json_suffix = ".manifest.json";

/// Format version a manifest must declare.
pub const catalog_format_version_supported: i64 = 2;

pub const IssueSeverity = enum {
    @"error",
    warning,
    info,

    pub fn jsonString(self: IssueSeverity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
        };
    }
};

pub const Issue = struct {
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
};

pub const DocRow = struct {
    name: []const u8 = "",
    doc: []const u8 = "",
    connect_example: []const u8 = "",
    when_to_call: []const u8 = "",

    pub fn deinit(self: *DocRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.doc);
        allocator.free(self.connect_example);
        allocator.free(self.when_to_call);
    }
};

pub const ManifestEntry = struct {
    manifest_path: []const u8,
    manifest_res_path: ?[]const u8 = null,
    catalog_format_version: i64 = catalog_format_version_supported,
    id: []const u8 = "",
    scene: []const u8 = "",
    scene_uid: []const u8 = "",
    tags: []const []const u8 = &.{},
    summary: []const u8 = "",
    when_to_use: []const u8 = "",
    when_not_to_use: []const u8 = "",
    related_ids: []const []const u8 = &.{},
    prefer_over_ids: []const []const u8 = &.{},
    notes: []const u8 = "",
    export_root_script: []const u8 = "",
    signal_docs: []DocRow = &.{},
    function_docs: []DocRow = &.{},
    issues: []Issue = &.{},
    valid: bool = false,

    pub fn deinit(self: *ManifestEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        if (self.manifest_res_path) |path| allocator.free(path);
        allocator.free(self.id);
        allocator.free(self.scene);
        allocator.free(self.scene_uid);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
        allocator.free(self.summary);
        allocator.free(self.when_to_use);
        allocator.free(self.when_not_to_use);
        for (self.related_ids) |item| allocator.free(item);
        allocator.free(self.related_ids);
        for (self.prefer_over_ids) |item| allocator.free(item);
        allocator.free(self.prefer_over_ids);
        allocator.free(self.notes);
        allocator.free(self.export_root_script);
        for (self.signal_docs) |*row| row.deinit(allocator);
        allocator.free(self.signal_docs);
        for (self.function_docs) |*row| row.deinit(allocator);
        allocator.free(self.function_docs);
        for (self.issues) |issue| {
            allocator.free(issue.code);
            allocator.free(issue.message);
        }
        allocator.free(self.issues);
    }
};

pub const ScanResult = struct {
    project_root: []const u8,
    manifest_files_found: usize = 0,
    entries: []ManifestEntry,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.project_root);
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn findValidEntryById(entries: []ManifestEntry, id: []const u8) ?*ManifestEntry {
    for (entries) |*entry| {
        if (entry.valid and std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub const ScanError = error{
    Io,
    OutOfMemory,
    ProjectRootRequired,
    InvalidProjectRoot,
};

pub fn scanProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
) ScanError!ScanResult {
    const norm_root = std.fs.path.resolve(allocator, &.{project_root}) catch return error.Io;
    errdefer allocator.free(norm_root);
    errdefer allocator.free(norm_root);

    const project_file = try std.fs.path.join(allocator, &.{ norm_root, "project.godot" });
    defer allocator.free(project_file);
    std.Io.Dir.cwd().access(io, project_file, .{}) catch return error.InvalidProjectRoot;

    var candidates: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidates.items) |path| allocator.free(path);
        candidates.deinit(allocator);
    }
    try collectCandidates(allocator, io, norm_root, &candidates);

    var entries: std.ArrayList(ManifestEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    // The filename already identified each candidate as a manifest, so a parse
    // failure is a broken manifest rather than an unrelated file.
    for (candidates.items) |path| {
        const entry = try parseJsonManifest(allocator, io, norm_root, path);
        try entries.append(allocator, entry);
    }

    try validateCollected(allocator, entries.items);

    const owned_root = try allocator.dupe(u8, norm_root);
    allocator.free(norm_root);
    const slice = try entries.toOwnedSlice(allocator);

    return .{
        .project_root = owned_root,
        .manifest_files_found = candidates.items.len,
        .entries = slice,
    };
}

fn openDirAt(io: std.Io, path: []const u8) ScanError!std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return error.Io;
    }
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return error.Io;
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) ScanError!void {
    var dir = try openDirAt(io, dir_path);
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const next = it.next(io) catch return error.Io;
        const entry = next orelse break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(child_path);

        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".godot")) {
                    allocator.free(child_path);
                    continue;
                }
                try collectCandidates(allocator, io, child_path, out);
                allocator.free(child_path);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, manifest_json_suffix)) {
                    allocator.free(child_path);
                    continue;
                }
                try out.append(allocator, child_path);
            },
            else => allocator.free(child_path),
        }
    }
}

/// Parse a `*.manifest.json` file.
///
/// Unparseable JSON yields an entry carrying an `invalid_json` error rather than
/// failing the whole scan: one broken manifest should not hide the rest of the
/// catalog, and `catalog validate` still fails on it.
fn parseJsonManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    manifest_path: []const u8,
) ScanError!ManifestEntry {
    var entry: ManifestEntry = .{
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .catalog_format_version = catalog_format_version_supported,
    };
    errdefer entry.deinit(allocator);

    entry.manifest_res_path = try project_config.filesystemToResPath(allocator, project_root, manifest_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch {
        return try jsonManifestError(allocator, entry, "manifest file could not be read");
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return try jsonManifestError(allocator, entry, "manifest is not valid JSON");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return try jsonManifestError(allocator, entry, "manifest must be a JSON object"),
    };

    entry.catalog_format_version = jsonInt(root, "catalog_format_version") orelse catalog_format_version_supported;
    entry.id = try jsonString(allocator, root, "id");
    entry.scene = try jsonString(allocator, root, "scene");
    entry.scene_uid = try jsonString(allocator, root, "scene_uid");
    entry.tags = try jsonStringList(allocator, root, "tags");
    entry.summary = try jsonString(allocator, root, "summary");
    entry.when_to_use = try jsonString(allocator, root, "when_to_use");
    entry.when_not_to_use = try jsonString(allocator, root, "when_not_to_use");
    entry.related_ids = try jsonStringList(allocator, root, "related_ids");
    entry.prefer_over_ids = try jsonStringList(allocator, root, "prefer_over_ids");
    entry.notes = try jsonString(allocator, root, "notes");
    entry.export_root_script = try jsonString(allocator, root, "export_root_script");
    entry.signal_docs = try jsonDocRows(allocator, root, "signals");
    entry.function_docs = try jsonDocRows(allocator, root, "functions");

    try validateEntry(allocator, io, project_root, &entry);
    return entry;
}

fn jsonManifestError(
    allocator: std.mem.Allocator,
    entry_in: ManifestEntry,
    message: []const u8,
) ScanError!ManifestEntry {
    var entry = entry_in;
    var issues: std.ArrayList(Issue) = .empty;
    errdefer freeIssues(allocator, &issues);
    try appendIssue(allocator, &issues, .@"error", "invalid_json", message);
    entry.issues = try issues.toOwnedSlice(allocator);
    entry.valid = false;
    return entry;
}

fn jsonString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ScanError![]const u8 {
    const value = obj.get(key) orelse return try allocator.dupe(u8, "");
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn jsonStringList(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ScanError![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |a| a,
        else => return &.{},
    };

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (array.items) |item| {
        switch (item) {
            .string => |s| try items.append(allocator, try allocator.dupe(u8, s)),
            else => {},
        }
    }
    return try items.toOwnedSlice(allocator);
}

fn jsonDocRows(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ScanError![]DocRow {
    const value = obj.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |a| a,
        else => return &.{},
    };

    var rows: std.ArrayList(DocRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    for (array.items) |item| {
        const row_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var row: DocRow = .{
            .name = try jsonString(allocator, row_obj, "name"),
            .doc = "",
            .connect_example = "",
            .when_to_call = "",
        };
        errdefer row.deinit(allocator);
        row.doc = try jsonString(allocator, row_obj, "doc");
        row.connect_example = try jsonString(allocator, row_obj, "connect_example");
        row.when_to_call = try jsonString(allocator, row_obj, "when_to_call");
        try rows.append(allocator, row);
    }
    return try rows.toOwnedSlice(allocator);
}

/// Field validation shared by both manifest formats. Populates `entry.issues`
/// and `entry.valid`, and back-fills `scene_uid` from the scene header when the
/// manifest omitted it.
fn validateEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    entry: *ManifestEntry,
) ScanError!void {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer freeIssues(allocator, &issues);

    if (entry.catalog_format_version != catalog_format_version_supported) {
        const message = try std.fmt.allocPrint(
            allocator,
            "catalog_format_version must be {d}",
            .{catalog_format_version_supported},
        );
        defer allocator.free(message);
        try appendIssue(allocator, &issues, .@"error", "unsupported_format_version", message);
    }
    if (entry.id.len == 0) try appendIssue(allocator, &issues, .@"error", "missing_id", "catalog id is required");
    if (entry.scene.len == 0) {
        try appendIssue(allocator, &issues, .@"error", "missing_scene", "scene path is required");
    } else if (!std.mem.startsWith(u8, entry.scene, "res://")) {
        try appendIssue(allocator, &issues, .@"error", "invalid_scene_path", "scene must be a res:// path");
    } else if (try project_config.resPathToFilesystem(allocator, project_root, entry.scene)) |fs_path| {
        defer allocator.free(fs_path);
        std.Io.Dir.cwd().access(io, fs_path, .{}) catch {
            try appendIssue(allocator, &issues, .@"error", "scene_not_found", "scene file does not exist under project root");
        };
        const header_uid = readSceneHeaderUid(allocator, io, fs_path) catch null;
        if (header_uid) |uid_text| {
            defer allocator.free(uid_text);
            if (entry.scene_uid.len == 0) {
                const copy = try allocator.dupe(u8, uid_text);
                allocator.free(entry.scene_uid);
                entry.scene_uid = copy;
            } else if (!std.mem.eql(u8, entry.scene_uid, uid_text)) {
                try appendIssue(allocator, &issues, .warning, "scene_uid_mismatch", "scene_uid does not match scene file header");
            }
        }
    } else {
        try appendIssue(allocator, &issues, .@"error", "invalid_scene_path", "scene path could not be resolved under project root");
    }

    if (entry.summary.len == 0) try appendIssue(allocator, &issues, .warning, "missing_summary", "summary is empty");
    if (entry.tags.len == 0) try appendIssue(allocator, &issues, .warning, "missing_tags", "tags are empty");
    if (entry.when_to_use.len == 0) try appendIssue(allocator, &issues, .warning, "missing_when_to_use", "when_to_use is empty");

    entry.issues = try issues.toOwnedSlice(allocator);
    entry.valid = !hasErrorIssues(entry.issues);
}

fn validateCollected(allocator: std.mem.Allocator, entries: []ManifestEntry) ScanError!void {
    for (entries, 0..) |*entry, i| {
        for (entries[i + 1 ..]) |*other| {
            if (entry.id.len > 0 and std.mem.eql(u8, entry.id, other.id)) {
                try pushIssue(allocator, entry, .@"error", "duplicate_id", "duplicate catalog id");
                try pushIssue(allocator, other, .@"error", "duplicate_id", "duplicate catalog id");
            }
            if (entry.scene.len > 0 and std.mem.eql(u8, entry.scene, other.scene)) {
                try pushIssue(allocator, entry, .@"error", "duplicate_scene", "multiple manifests reference the same scene");
                try pushIssue(allocator, other, .@"error", "duplicate_scene", "multiple manifests reference the same scene");
            }
        }
    }
}

fn pushIssue(
    allocator: std.mem.Allocator,
    entry: *ManifestEntry,
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
) ScanError!void {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer freeIssues(allocator, &issues);

    // Copying the Issue structs moves their `code`/`message` allocations to the
    // new list — only the old backing array is this function's to free. Freeing
    // the strings here would leave every pre-existing issue dangling, which is
    // precisely the case this runs in: an entry that already has warnings and
    // then turns out to be a duplicate.
    try issues.ensureTotalCapacity(allocator, entry.issues.len + 1);
    issues.appendSliceAssumeCapacity(entry.issues);
    const old_array = entry.issues;
    entry.issues = &.{};
    allocator.free(old_array);

    try appendIssue(allocator, &issues, severity, code, message);
    entry.issues = try issues.toOwnedSlice(allocator);
    entry.valid = !hasErrorIssues(entry.issues);
}

fn hasErrorIssues(issues: []const Issue) bool {
    for (issues) |issue| {
        if (issue.severity == .@"error") return true;
    }
    return false;
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(Issue),
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
) ScanError!void {
    try issues.append(allocator, .{
        .severity = severity,
        .code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
    });
}

fn freeIssues(allocator: std.mem.Allocator, issues: *std.ArrayList(Issue)) void {
    for (issues.items) |issue| {
        allocator.free(issue.code);
        allocator.free(issue.message);
    }
    issues.deinit(allocator);
}

fn readSceneHeaderUid(allocator: std.mem.Allocator, io: std.Io, scene_path: []const u8) ScanError!?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, scene_path, allocator, .unlimited) catch return null;
    defer allocator.free(bytes);
    var doc = document.parseBytes(allocator, bytes) catch return null;
    defer doc.deinit(allocator);
    if (doc.sections.items.len == 0) return null;
    const header = &doc.sections.items[0].header;
    if (!std.mem.eql(u8, header.name, "gd_scene")) return null;
    if (header.getString("uid")) |uid_text| return try allocator.dupe(u8, uid_text);
    return null;
}

test "scan button manifest fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var result = try scanProject(allocator, io, "test_fixtures/project");
    defer result.deinit(allocator);

    try std.testing.expect(result.manifest_files_found >= 1);
    try std.testing.expect(result.entries.len >= 1);

    const entry = blk: {
        for (result.entries) |*item| {
            if (std.mem.eql(u8, item.id, "ui/button")) break :blk item;
        }
        return error.TestExpectedEqual;
    };

    try std.testing.expectEqualStrings("ui/button", entry.id);
    try std.testing.expectEqualStrings("res://ui/button/button.tscn", entry.scene);
    try std.testing.expect(entry.valid);
    try std.testing.expect(entry.tags.len == 3);
    try std.testing.expect(entry.signal_docs.len == 1);
    try std.testing.expectEqualStrings("button_pressed", entry.signal_docs[0].name);
}

test "scan json manifest fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var result = try scanProject(allocator, io, "test_fixtures/project");
    defer result.deinit(allocator);

    try std.testing.expect(result.manifest_files_found >= 1);

    const entry = blk: {
        for (result.entries) |*item| {
            if (std.mem.eql(u8, item.id, "fx/instanced_child")) break :blk item;
        }
        return error.TestExpectedEqual;
    };

    try std.testing.expectEqual(catalog_format_version_supported, entry.catalog_format_version);
    try std.testing.expectEqualStrings("res://instanced_child.tscn", entry.scene);
    try std.testing.expectEqualStrings("Reusable child scene used by instancing tests", entry.summary);
    try std.testing.expect(entry.tags.len == 2);
    try std.testing.expect(entry.signal_docs.len == 1);
    try std.testing.expectEqualStrings("child_ready", entry.signal_docs[0].name);
    try std.testing.expect(entry.valid);
}

test "json manifest declaring the wrong format version is rejected" {
    const allocator = std.testing.allocator;
    var entry: ManifestEntry = .{
        .manifest_path = try allocator.dupe(u8, "x.manifest.json"),
        .catalog_format_version = 1,
        .id = try allocator.dupe(u8, "x"),
        .scene = try allocator.dupe(u8, "res://x.tscn"),
    };
    defer entry.deinit(allocator);

    try validateEntry(allocator, std.testing.io, "test_fixtures/project", &entry);
    try std.testing.expect(!entry.valid);

    var found = false;
    for (entry.issues) |issue| {
        if (std.mem.eql(u8, issue.code, "unsupported_format_version")) found = true;
    }
    try std.testing.expect(found);
}

test "pushIssue keeps earlier issue strings intact" {
    const allocator = std.testing.allocator;
    var entry: ManifestEntry = .{
        .manifest_path = try allocator.dupe(u8, "x.manifest.json"),
        .catalog_format_version = catalog_format_version_supported,
        .id = try allocator.dupe(u8, "x"),
        .scene = try allocator.dupe(u8, "res://x.tscn"),
    };
    defer entry.deinit(allocator);

    // Two warnings, then a duplicate error on top — the shape that used to leave
    // the first two pointing at freed memory.
    try validateEntry(allocator, std.testing.io, "test_fixtures/project", &entry);
    const warning_count = entry.issues.len;
    try std.testing.expect(warning_count > 0);

    try pushIssue(allocator, &entry, .@"error", "duplicate_scene", "multiple manifests reference the same scene");

    try std.testing.expectEqual(warning_count + 1, entry.issues.len);
    for (entry.issues) |issue| {
        try std.testing.expect(issue.code.len > 0);
        // 0xAA is the debug-allocator fill for freed memory.
        for (issue.code) |c| try std.testing.expect(c != 0xAA);
        for (issue.message) |c| try std.testing.expect(c != 0xAA);
    }
    try std.testing.expectEqualStrings("duplicate_scene", entry.issues[entry.issues.len - 1].code);
}
