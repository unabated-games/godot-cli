//! Autoload singletons in `project.godot` `[autoload]` section.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const project_config = @import("project_config.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    DuplicateName,
    InvalidPath,
} || project_godot.Error;

pub const AutoloadInfo = struct {
    name: []const u8,
    path: []const u8,
    singleton: bool,
    order: usize,

    pub fn deinit(self: *const AutoloadInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const ApplyResult = struct {
    applied_names: []const []const u8,
    removed_count: usize,
    added_count: usize,
    replaced_count: usize,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.applied_names) |name| allocator.free(name);
        allocator.free(self.applied_names);
    }
};

pub fn parseAutoloadValue(value: []const u8) struct { path: []const u8, singleton: bool } {
    const text = project_godot.unquoteValue(value) orelse value;
    if (text.len > 0 and text[0] == '*') {
        return .{ .path = text[1..], .singleton = true };
    }
    return .{ .path = text, .singleton = false };
}

pub fn formatAutoloadValue(allocator: std.mem.Allocator, path: []const u8, singleton: bool) Error![]u8 {
    if (singleton) {
        var prefixed: std.ArrayList(u8) = .empty;
        errdefer prefixed.deinit(allocator);
        try prefixed.append(allocator, '*');
        try prefixed.appendSlice(allocator, path);
        const combined = try prefixed.toOwnedSlice(allocator);
        defer allocator.free(combined);
        return project_godot.formatQuotedString(allocator, combined);
    }
    return project_godot.formatQuotedString(allocator, path);
}

pub fn listAutoloads(allocator: std.mem.Allocator, section: *const project_godot.Section) Error![]AutoloadInfo {
    var out: std.ArrayList(AutoloadInfo) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (section.entries.items, 0..) |entry, index| {
        const parsed = parseAutoloadValue(entry.value);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key),
            .path = try allocator.dupe(u8, parsed.path),
            .singleton = parsed.singleton,
            .order = index,
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn validateAutoloadPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "res://")) return false;
    const suffixes = [_][]const u8{ ".gd", ".tscn", ".cs" };
    for (suffixes) |suffix| {
        if (path.len >= suffix.len and std.ascii.eqlIgnoreCase(path[path.len - suffix.len ..], suffix)) return true;
    }
    return false;
}

pub fn applyIntentJson(
    allocator: std.mem.Allocator,
    doc: *project_godot.Document,
    intent_json: []const u8,
) Error!ApplyResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, intent_json, .{}) catch return error.InvalidIntent;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidIntent;
    const autoloads_value = root.object.get("autoloads") orelse return error.MissingIntentField;
    if (autoloads_value != .array) return error.InvalidIntent;

    const replace_all = if (root.object.get("replace_all")) |mode| blk: {
        if (mode != .bool) return error.InvalidIntent;
        break :blk mode.bool;
    } else false;

    const section = try doc.ensureSection(allocator, "autoload");
    var applied: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (applied.items) |name| allocator.free(name);
        applied.deinit(allocator);
    }

    var removed: usize = 0;
    var added: usize = 0;
    var replaced: usize = 0;

    if (replace_all) {
        while (section.entries.items.len > 0) {
            const old = section.entries.items[0];
            allocator.free(old.key);
            allocator.free(old.value);
            _ = section.entries.orderedRemove(0);
            removed += 1;
        }
    }

    for (autoloads_value.array.items) |*entry_value| {
        if (entry_value.* != .object) return error.InvalidIntent;
        const entry = entry_value.object;

        const name_value = entry.get("name") orelse return error.MissingIntentField;
        if (name_value != .string or name_value.string.len == 0) return error.InvalidIntent;
        const name = name_value.string;

        const path_value = entry.get("path") orelse return error.MissingIntentField;
        if (path_value != .string or path_value.string.len == 0) return error.InvalidIntent;
        if (!validateAutoloadPath(path_value.string)) return error.InvalidPath;

        const singleton = if (entry.get("singleton")) |v| blk: {
            if (v != .bool) return error.InvalidIntent;
            break :blk v.bool;
        } else true;

        const formatted = try formatAutoloadValue(allocator, path_value.string, singleton);
        defer allocator.free(formatted);

        const existed = section.findEntry(name) != null;
        try section.setEntry(allocator, name, formatted);
        try applied.append(allocator, try allocator.dupe(u8, name));
        if (existed) replaced += 1 else added += 1;
    }

    return .{
        .applied_names = try applied.toOwnedSlice(allocator),
        .removed_count = removed,
        .added_count = added,
        .replaced_count = replaced,
    };
}

pub fn validateAutoloadSection(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    section: *const project_godot.Section,
) Error!usize {
    var issue_count: usize = 0;
    const autoloads = try listAutoloads(allocator, section);
    defer {
        for (autoloads) |*item| item.deinit(allocator);
        allocator.free(autoloads);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (autoloads) |item| {
        if (!validateAutoloadPath(item.path)) issue_count += 1;
        const gop = seen.getOrPut(item.name) catch return error.OutOfMemory;
        if (gop.found_existing) issue_count += 1 else gop.value_ptr.* = {};

        const fs_path = project_config.resPathToFilesystem(allocator, project_root, item.path) catch null;
        if (fs_path) |path| {
            defer allocator.free(path);
            std.Io.Dir.cwd().access(io, path, .{}) catch {
                issue_count += 1;
                continue;
            };
        } else issue_count += 1;
    }

    return issue_count;
}

test "format autoload singleton path" {
    const allocator = std.testing.allocator;
    const value = try formatAutoloadValue(allocator, "res://global.gd", true);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("\"*res://global.gd\"", value);
}

test "apply autoload intent merge" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "autoloads": [
        \\    { "name": "GameState", "path": "res://id_reference.gd", "singleton": true }
        \\  ]
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.added_count);
    const section = doc.sectionMut("autoload").?;
    try std.testing.expect(section.findEntry("GameState") != null);
}

test "list autoloads from fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/autoload_snippet.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const section = doc.sectionMut("autoload").?;
    const autoloads = try listAutoloads(allocator, section);
    defer {
        for (autoloads) |*item| item.deinit(allocator);
        allocator.free(autoloads);
    }

    try std.testing.expectEqual(@as(usize, 2), autoloads.len);
    try std.testing.expect(autoloads[0].singleton);
    try std.testing.expectEqualStrings("GameState", autoloads[0].name);
}
