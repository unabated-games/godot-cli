//! Rendering backend settings in `project.godot` `[rendering]` section.

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
    .{ .alias = "method", .key = "renderer/rendering_method" },
    .{ .alias = "method_mobile", .key = "renderer/rendering_method.mobile" },
    .{ .alias = "driver_windows", .key = "rendering_device/driver.windows" },
    .{ .alias = "driver_macos", .key = "rendering_device/driver.macos" },
    .{ .alias = "driver_linux", .key = "rendering_device/driver.linux" },
    .{ .alias = "driver_android", .key = "rendering_device/driver.android" },
    .{ .alias = "driver_ios", .key = "rendering_device/driver.ios" },
};

const known_methods = [_][]const u8{ "forward_plus", "mobile", "gl_compatibility", "dummy" };
const known_drivers = [_][]const u8{ "vulkan", "d3d12", "metal", "opengl3", "dummy" };

pub fn resolveKey(name: []const u8) ?[]const u8 {
    for (known_aliases) |entry| {
        if (std.mem.eql(u8, entry.alias, name)) return entry.key;
    }
    if (std.mem.startsWith(u8, name, "renderer/") or
        std.mem.startsWith(u8, name, "rendering_device/") or
        std.mem.startsWith(u8, name, "textures/") or
        std.mem.startsWith(u8, name, "anti_aliasing/"))
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

fn validateValue(key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "renderer/rendering_method") or std.mem.eql(u8, key, "renderer/rendering_method.mobile")) {
        for (known_methods) |method| {
            if (std.mem.eql(u8, method, value)) return true;
        }
        return false;
    }
    if (std.mem.startsWith(u8, key, "rendering_device/driver.")) {
        for (known_drivers) |driver| {
            if (std.mem.eql(u8, driver, value)) return true;
        }
        return false;
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
        if (entry.value_ptr.* != .string) return error.InvalidIntent;
        if (!validateValue(resolved, entry.value_ptr.string)) return error.UnknownValue;
        const existed = try project_settings.setSetting(allocator, doc, "rendering", resolved, entry.value_ptr.*);
        const label = try std.fmt.allocPrint(allocator, "rendering/{s}", .{resolved});
        try applied.append(allocator, label);
        if (existed) replaced += 1 else added += 1;
    }

    return .{
        .applied_keys = try applied.toOwnedSlice(allocator),
        .replaced_count = replaced,
        .added_count = added,
    };
}

pub fn validateRenderingSection(doc: *const project_godot.Document) usize {
    const index = doc.sectionIndex("rendering") orelse return 0;
    const section = &doc.sections.items[index];
    var issue_count: usize = 0;
    for (section.entries.items) |entry| {
        const value = project_godot.unquoteValue(entry.value) orelse entry.value;
        if (!validateValue(entry.key, value)) issue_count += 1;
    }
    return issue_count;
}

test "apply rendering intent aliases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "method": "forward_plus",
        \\  "method_mobile": "mobile",
        \\  "driver_windows": "d3d12"
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.added_count);
    const method = project_settings.getSetting(&doc, "rendering", "renderer/rendering_method").?;
    try std.testing.expectEqualStrings("forward_plus", method);
}
