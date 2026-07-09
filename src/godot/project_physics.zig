//! Physics settings in `project.godot` `[physics]` section.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const project_settings = @import("project_settings.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    UnknownKey,
    UnknownValue,
} || project_godot.Error || project_settings.Error;

pub const AliasInfo = struct {
    alias: []const u8,
    key: []const u8,
};

pub const known_aliases = [_]AliasInfo{
    .{ .alias = "engine_3d", .key = "3d/physics_engine" },
    .{ .alias = "engine_2d", .key = "2d/physics_engine" },
    .{ .alias = "gravity_3d", .key = "3d/default_gravity" },
    .{ .alias = "gravity_2d", .key = "2d/default_gravity" },
    .{ .alias = "physics_interpolation", .key = "common/physics_interpolation" },
    .{ .alias = "physics_ticks_per_second", .key = "common/physics_ticks_per_second" },
};

const known_engines_3d = [_][]const u8{ "DEFAULT", "GodotPhysics3D", "Jolt Physics", "dummy" };
const known_engines_2d = [_][]const u8{ "DEFAULT", "GodotPhysics", "dummy" };

pub fn resolveKey(name: []const u8) ?[]const u8 {
    for (known_aliases) |entry| {
        if (std.mem.eql(u8, entry.alias, name)) return entry.key;
    }
    if (std.mem.startsWith(u8, name, "3d/") or
        std.mem.startsWith(u8, name, "2d/") or
        std.mem.startsWith(u8, name, "common/"))
    {
        return name;
    }
    return null;
}

pub fn aliasForKey(key: []const u8) ?[]const u8 {
    for (known_aliases) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.alias;
    }
    return null;
}

fn validateValue(key: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, key, "3d/physics_engine")) {
        if (value != .string) return false;
        for (known_engines_3d) |engine| {
            if (std.mem.eql(u8, engine, value.string)) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, key, "2d/physics_engine")) {
        if (value != .string) return false;
        for (known_engines_2d) |engine| {
            if (std.mem.eql(u8, engine, value.string)) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, key, "common/physics_interpolation")) {
        return value == .bool;
    }
    if (std.mem.eql(u8, key, "common/physics_ticks_per_second") or
        std.mem.eql(u8, key, "3d/default_gravity") or
        std.mem.eql(u8, key, "2d/default_gravity"))
    {
        return value == .integer or value == .float;
    }
    return true;
}

pub fn applyIntentJson(
    allocator: std.mem.Allocator,
    doc: *project_godot.Document,
    intent_json: []const u8,
) Error!project_settings.ApplyResult {
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

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const resolved = resolveKey(entry.key_ptr.*) orelse return error.UnknownKey;
        if (!validateValue(resolved, entry.value_ptr.*)) return error.UnknownValue;
        const existed = try project_settings.setSetting(allocator, doc, "physics", resolved, entry.value_ptr.*);
        const label = try std.fmt.allocPrint(allocator, "physics/{s}", .{resolved});
        try applied.append(allocator, label);
        if (existed) replaced += 1 else added += 1;
    }

    return .{
        .applied_keys = try applied.toOwnedSlice(allocator),
        .replaced_count = replaced,
        .added_count = added,
    };
}

pub fn validatePhysicsSection(doc: *const project_godot.Document) usize {
    const index = doc.sectionIndex("physics") orelse return 0;
    const section = &doc.sections.items[index];
    var issue_count: usize = 0;
    for (section.entries.items) |entry| {
        const value_text = project_godot.unquoteValue(entry.value) orelse entry.value;
        var value: std.json.Value = .{ .string = value_text };
        if (std.fmt.parseInt(i64, value_text, 10) catch null) |n| {
            value = .{ .integer = n };
        } else if (std.fmt.parseFloat(f64, value_text) catch null) |f| {
            value = .{ .float = f };
        } else if (std.mem.eql(u8, value_text, "true")) {
            value = .{ .bool = true };
        } else if (std.mem.eql(u8, value_text, "false")) {
            value = .{ .bool = false };
        }
        if (!validateValue(entry.key, value)) issue_count += 1;
    }
    return issue_count;
}

test "apply physics intent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "engine_3d": "Jolt Physics",
        \\  "gravity_3d": 980
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.added_count);
    const engine = project_settings.getSetting(&doc, "physics", "3d/physics_engine").?;
    try std.testing.expectEqualStrings("Jolt Physics", engine);
}
