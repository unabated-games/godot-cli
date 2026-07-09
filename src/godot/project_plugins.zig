//! Editor plugin enable/disable in `project.godot` `[editor_plugins]` section.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const project_config = @import("project_config.zig");
const variant = @import("variant/root.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    InvalidPluginPath,
    PluginNotFound,
} || project_godot.Error;

pub const PluginInfo = struct {
    path: []const u8,
    enabled: bool,
    name: []const u8,

    pub fn deinit(self: *const PluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
    }
};

pub const ApplyResult = struct {
    enabled_paths: []const []const u8,
    enabled_count: usize,
    disabled_count: usize,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.enabled_paths) |path| allocator.free(path);
        allocator.free(self.enabled_paths);
    }
};

const enabled_key = "enabled";

pub fn normalizePluginPath(allocator: std.mem.Allocator, path: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, path, "res://")) {
        if (std.mem.endsWith(u8, path, "plugin.cfg")) return try allocator.dupe(u8, path);
        if (std.mem.endsWith(u8, path, "/")) {
            return try std.fmt.allocPrint(allocator, "{s}plugin.cfg", .{path});
        }
        return try std.fmt.allocPrint(allocator, "{s}/plugin.cfg", .{path});
    }
    if (std.mem.startsWith(u8, path, "addons/")) {
        return try std.fmt.allocPrint(allocator, "res://{s}/plugin.cfg", .{std.mem.trim(u8, path["addons/".len..], "/")});
    }
    return try std.fmt.allocPrint(allocator, "res://addons/{s}/plugin.cfg", .{std.mem.trim(u8, path, "/")});
}

pub fn parseEnabledPaths(allocator: std.mem.Allocator, section: ?*const project_godot.Section) Error![]const []const u8 {
    const sec = section orelse return try allocator.alloc([]const u8, 0);
    const raw = sec.getEntry(enabled_key) orelse return try allocator.alloc([]const u8, 0);
    var parsed = variant.parse.parsePropertyValue(allocator, raw) catch return try allocator.alloc([]const u8, 0);
    defer parsed.deinit(allocator);

    if (parsed.kind != .packed_array or parsed.elements == null) return try allocator.alloc([]const u8, 0);
    const elements = parsed.elements.?;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    for (elements) |element| {
        if (element.kind != .string and element.kind != .string_name) continue;
        try out.append(allocator, try allocator.dupe(u8, element.string));
    }

    return try out.toOwnedSlice(allocator);
}

fn writeEnabledPaths(allocator: std.mem.Allocator, section: *project_godot.Section, paths: []const []const u8) Error!void {
    if (paths.len == 0) {
        try section.setEntry(allocator, enabled_key, "PackedStringArray()");
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "PackedStringArray(");
    for (paths, 0..) |path, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        const quoted = try project_godot.formatQuotedString(allocator, path);
        defer allocator.free(quoted);
        try out.appendSlice(allocator, quoted);
    }
    try out.append(allocator, ')');
    const formatted = try out.toOwnedSlice(allocator);
    defer allocator.free(formatted);
    try section.setEntry(allocator, enabled_key, formatted);
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |existing| {
        if (std.mem.eql(u8, existing, path)) return true;
    }
    return false;
}

pub fn listPlugins(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    section: ?*const project_godot.Section,
) Error![]PluginInfo {
    const enabled_paths = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled_paths) |path| allocator.free(path);
        allocator.free(enabled_paths);
    }

    var out: std.ArrayList(PluginInfo) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    const addons_dir = try std.fs.path.join(allocator, &.{ project_root, "addons" });
    defer allocator.free(addons_dir);

    var dir = std.Io.Dir.cwd().openDir(io, addons_dir, .{ .iterate = true }) catch return try out.toOwnedSlice(allocator);
    defer dir.close(io);

    var iterator = dir.iterate();
    while (true) {
        const next = iterator.next(io) catch return error.Io;
        const entry = next orelse break;
        if (entry.kind != .directory) continue;
        const plugin_cfg = try std.fmt.allocPrint(allocator, "res://addons/{s}/plugin.cfg", .{entry.name});
        defer allocator.free(plugin_cfg);

        const fs_cfg = try std.fmt.allocPrint(allocator, "{s}/{s}/plugin.cfg", .{ addons_dir, entry.name });
        defer allocator.free(fs_cfg);
        std.Io.Dir.cwd().access(io, fs_cfg, .{}) catch continue;

        const enabled = containsPath(enabled_paths, plugin_cfg);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, plugin_cfg),
            .enabled = enabled,
            .name = try allocator.dupe(u8, entry.name),
        });
    }

    for (enabled_paths) |path| {
        if (containsPathSlice(out.items, path)) continue;
        const name = pluginNameFromPath(path) orelse "unknown";
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .enabled = true,
            .name = try allocator.dupe(u8, name),
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn containsPathSlice(items: []const PluginInfo, path: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.path, path)) return true;
    }
    return false;
}

fn pluginNameFromPath(path: []const u8) ?[]const u8 {
    const prefix = "res://addons/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

pub fn setEnabledPaths(allocator: std.mem.Allocator, doc: *project_godot.Document, paths: []const []const u8) Error!void {
    const section = try doc.ensureSection(allocator, "editor_plugins");
    try writeEnabledPaths(allocator, section, paths);
}

pub fn enablePlugin(allocator: std.mem.Allocator, doc: *project_godot.Document, plugin_path: []const u8) Error!bool {
    const normalized = try normalizePluginPath(allocator, plugin_path);
    defer allocator.free(normalized);

    const section = try doc.ensureSection(allocator, "editor_plugins");
    const enabled = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled) |path| allocator.free(path);
        allocator.free(enabled);
    }

    if (containsPath(enabled, normalized)) return false;

    var next: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (next.items) |path| allocator.free(path);
        next.deinit(allocator);
    }
    for (enabled) |path| try next.append(allocator, try allocator.dupe(u8, path));
    try next.append(allocator, try allocator.dupe(u8, normalized));

    try writeEnabledPaths(allocator, section, next.items);
    for (next.items) |path| allocator.free(path);
    next.deinit(allocator);
    return true;
}

pub fn disablePlugin(allocator: std.mem.Allocator, doc: *project_godot.Document, plugin_path: []const u8) Error!bool {
    const normalized = try normalizePluginPath(allocator, plugin_path);
    defer allocator.free(normalized);

    const section = doc.sectionMut("editor_plugins") orelse return false;
    const enabled = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled) |path| allocator.free(path);
        allocator.free(enabled);
    }

    var next: std.ArrayList([]const u8) = .empty;
    defer {
        for (next.items) |path| allocator.free(path);
        next.deinit(allocator);
    }

    var removed = false;
    for (enabled) |path| {
        if (std.mem.eql(u8, path, normalized)) {
            removed = true;
            continue;
        }
        try next.append(allocator, try allocator.dupe(u8, path));
    }

    if (!removed) return false;
    try writeEnabledPaths(allocator, section, next.items);
    return true;
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

    const section = try doc.ensureSection(allocator, "editor_plugins");
    var enabled_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (enabled_list.items) |path| allocator.free(path);
        enabled_list.deinit(allocator);
    }

    const initial = try parseEnabledPaths(allocator, section);
    defer {
        for (initial) |path| allocator.free(path);
        allocator.free(initial);
    }
    for (initial) |path| {
        try enabled_list.append(allocator, try allocator.dupe(u8, path));
    }

    var enabled_count: usize = 0;
    var disabled_count: usize = 0;

    if (root.object.get("replace_enabled")) |replace_value| {
        if (replace_value != .array) return error.InvalidIntent;
        for (enabled_list.items) |path| allocator.free(path);
        enabled_list.clearRetainingCapacity();

        for (replace_value.array.items) |*item| {
            if (item.* != .string) return error.InvalidIntent;
            const normalized = try normalizePluginPath(allocator, item.string);
            try enabled_list.append(allocator, normalized);
        }
        enabled_count = enabled_list.items.len;
    } else {
        if (root.object.get("enable")) |enable_value| {
            if (enable_value != .array) return error.InvalidIntent;
            for (enable_value.array.items) |*item| {
                if (item.* != .string) return error.InvalidIntent;
                const normalized = try normalizePluginPath(allocator, item.string);
                defer allocator.free(normalized);
                if (!containsPath(enabled_list.items, normalized)) {
                    try enabled_list.append(allocator, try allocator.dupe(u8, normalized));
                    enabled_count += 1;
                }
            }
        }

        if (root.object.get("disable")) |disable_value| {
            if (disable_value != .array) return error.InvalidIntent;
            for (disable_value.array.items) |*item| {
                if (item.* != .string) return error.InvalidIntent;
                const normalized = try normalizePluginPath(allocator, item.string);
                defer allocator.free(normalized);

                var index: usize = 0;
                while (index < enabled_list.items.len) {
                    if (std.mem.eql(u8, enabled_list.items[index], normalized)) {
                        allocator.free(enabled_list.items[index]);
                        _ = enabled_list.orderedRemove(index);
                        disabled_count += 1;
                    } else index += 1;
                }
            }
        }

        if (enabled_count == 0 and disabled_count == 0 and root.object.get("enable") == null and root.object.get("disable") == null) {
            return error.MissingIntentField;
        }
    }

    try writeEnabledPaths(allocator, section, enabled_list.items);
    return .{
        .enabled_paths = try dupPaths(allocator, enabled_list.items),
        .enabled_count = enabled_count,
        .disabled_count = disabled_count,
    };
}

fn dupPaths(allocator: std.mem.Allocator, paths: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }
    for (paths) |path| try out.append(allocator, try allocator.dupe(u8, path));
    return try out.toOwnedSlice(allocator);
}

pub fn validatePlugins(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    section: ?*const project_godot.Section,
) Error!usize {
    var issue_count: usize = 0;
    const enabled_paths = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled_paths) |path| allocator.free(path);
        allocator.free(enabled_paths);
    }

    for (enabled_paths) |path| {
        if (!std.mem.startsWith(u8, path, "res://addons/") or !std.mem.endsWith(u8, path, "plugin.cfg")) {
            issue_count += 1;
            continue;
        }
        const fs_path = project_config.resPathToFilesystem(allocator, project_root, path) catch null;
        if (fs_path) |file_path| {
            defer allocator.free(file_path);
            std.Io.Dir.cwd().access(io, file_path, .{}) catch {
                issue_count += 1;
                continue;
            };
        } else issue_count += 1;
    }

    return issue_count;
}

test "normalize plugin path" {
    const allocator = std.testing.allocator;
    const full = try normalizePluginPath(allocator, "res://addons/foo/plugin.cfg");
    defer allocator.free(full);
    try std.testing.expectEqualStrings("res://addons/foo/plugin.cfg", full);

    const short = try normalizePluginPath(allocator, "foo");
    defer allocator.free(short);
    try std.testing.expectEqualStrings("res://addons/foo/plugin.cfg", short);
}

test "enable and disable plugin" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    try std.testing.expect(try enablePlugin(allocator, &doc, "sample_plugin"));
    const section = doc.sectionMut("editor_plugins").?;
    const enabled = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled) |path| allocator.free(path);
        allocator.free(enabled);
    }
    try std.testing.expectEqual(@as(usize, 1), enabled.len);

    try std.testing.expect(try disablePlugin(allocator, &doc, "res://addons/sample_plugin/plugin.cfg"));
    const enabled2 = try parseEnabledPaths(allocator, section);
    defer {
        for (enabled2) |path| allocator.free(path);
        allocator.free(enabled2);
    }
    try std.testing.expectEqual(@as(usize, 0), enabled2.len);
}
