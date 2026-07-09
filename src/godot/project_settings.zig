//! Scalar `project.godot` settings (application, display, layer_names, …).

const std = @import("std");
const project_godot = @import("project_godot.zig");
const project_config = @import("project_config.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    InvalidSection,
    InvalidKey,
    InvalidValue,
    MissingResPath,
} || project_godot.Error;

pub const SettingInfo = struct {
    section: []const u8,
    key: []const u8,
    value: []const u8,
    value_text: []const u8,

    pub fn deinit(self: *const SettingInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.section);
        allocator.free(self.key);
        allocator.free(self.value);
        allocator.free(self.value_text);
    }
};

pub const ApplyResult = struct {
    applied_keys: []const []const u8,
    added_count: usize,
    replaced_count: usize,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.applied_keys) |key| allocator.free(key);
        allocator.free(self.applied_keys);
    }
};

pub fn listSection(allocator: std.mem.Allocator, section: *const project_godot.Section, section_name: []const u8) Error![]SettingInfo {
    var out: std.ArrayList(SettingInfo) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (section.entries.items) |entry| {
        const value_text = project_godot.unquoteValue(entry.value) orelse entry.value;
        try out.append(allocator, .{
            .section = try allocator.dupe(u8, section_name),
            .key = try allocator.dupe(u8, entry.key),
            .value = try allocator.dupe(u8, value_text),
            .value_text = try allocator.dupe(u8, entry.value),
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn listAll(allocator: std.mem.Allocator, doc: *const project_godot.Document, section_filter: ?[]const u8) Error![]SettingInfo {
    var out: std.ArrayList(SettingInfo) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (doc.sections.items) |section| {
        if (section_filter) |wanted| {
            if (!std.mem.eql(u8, section.name, wanted)) continue;
        }
        for (section.entries.items) |entry| {
            const value_text = project_godot.unquoteValue(entry.value) orelse entry.value;
            try out.append(allocator, .{
                .section = try allocator.dupe(u8, section.name),
                .key = try allocator.dupe(u8, entry.key),
                .value = try allocator.dupe(u8, value_text),
                .value_text = try allocator.dupe(u8, entry.value),
            });
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn getSetting(doc: *const project_godot.Document, section_name: []const u8, key: []const u8) ?[]const u8 {
    const index = doc.sectionIndex(section_name) orelse return null;
    const section = &doc.sections.items[index];
    const raw = section.getEntry(key) orelse return null;
    return project_godot.unquoteValue(raw) orelse raw;
}

pub fn setSetting(
    allocator: std.mem.Allocator,
    doc: *project_godot.Document,
    section_name: []const u8,
    key: []const u8,
    value: std.json.Value,
) Error!bool {
    const section = try doc.ensureSection(allocator, section_name);
    const formatted = try project_godot.formatGodotValue(allocator, value);
    defer allocator.free(formatted);
    const existed = section.findEntry(key) != null;
    try section.setEntry(allocator, key, formatted);
    return existed;
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

    var applied: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (applied.items) |key| allocator.free(key);
        applied.deinit(allocator);
    }

    var replaced: usize = 0;
    var added: usize = 0;

    var section_it = root.object.iterator();
    while (section_it.next()) |section_entry| {
        if (section_entry.value_ptr.* != .object) return error.InvalidIntent;
        const section_name = section_entry.key_ptr.*;

        var key_it = section_entry.value_ptr.object.iterator();
        while (key_it.next()) |key_entry| {
            const key = key_entry.key_ptr.*;
            const existed = try setSetting(allocator, doc, section_name, key, key_entry.value_ptr.*);
            const label = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ section_name, key });
            try applied.append(allocator, label);
            if (existed) replaced += 1 else added += 1;
        }
    }

    return .{
        .applied_keys = try applied.toOwnedSlice(allocator),
        .replaced_count = replaced,
        .added_count = added,
    };
}

pub fn validateSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    doc: *const project_godot.Document,
    section_filter: ?[]const u8,
) Error!usize {
    var issue_count: usize = 0;
    const settings = try listAll(allocator, doc, section_filter);
    defer {
        for (settings) |*item| item.deinit(allocator);
        allocator.free(settings);
    }

    for (settings) |item| {
        if (!std.mem.startsWith(u8, item.value, "res://")) continue;
        const fs_path = project_config.resPathToFilesystem(allocator, project_root, item.value) catch null;
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

test "apply settings intent sets main scene" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "application": {
        \\    "run/main_scene": "res://scenes/main.tscn"
        \\  },
        \\  "display": {
        \\    "window/stretch/mode": "canvas_items"
        \\  }
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.added_count);
    const main_scene = getSetting(&doc, "application", "run/main_scene").?;
    try std.testing.expectEqualStrings("res://scenes/main.tscn", main_scene);
}
