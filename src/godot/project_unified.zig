//! Unified project.godot apply and summary helpers.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const project_json = @import("project_json.zig");
const project_input = @import("project_input.zig");
const project_settings = @import("project_settings.zig");
const project_autoload = @import("project_autoload.zig");
const project_plugins = @import("project_plugins.zig");
const project_rendering = @import("project_rendering.zig");
const project_physics = @import("project_physics.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentSection,
} || project_input.Error || project_settings.Error || project_autoload.Error || project_plugins.Error || project_rendering.Error || project_physics.Error;

pub const SectionResult = struct {
    name: []const u8,
    summary: []const u8,

    pub fn deinit(self: *const SectionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.summary);
    }
};

pub const ApplyResult = struct {
    sections: []const SectionResult,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.sections) |*section| section.deinit(allocator);
        allocator.free(self.sections);
    }
};

pub const Summary = struct {
    project_name: ?[]const u8,
    main_scene: ?[]const u8,
    input_action_count: usize,
    autoload_count: usize,
    enabled_plugin_count: usize,
    rendering_method: ?[]const u8,
    physics_engine_3d: ?[]const u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.project_name) |v| allocator.free(v);
        if (self.main_scene) |v| allocator.free(v);
        if (self.rendering_method) |v| allocator.free(v);
        if (self.physics_engine_3d) |v| allocator.free(v);
    }
};

fn appendSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(SectionResult),
    name: []const u8,
    summary: []const u8,
) Error!void {
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .summary = try allocator.dupe(u8, summary),
    });
}

fn applySubsection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(SectionResult),
    name: []const u8,
    value: std.json.Value,
    comptime apply_fn: *const fn (std.mem.Allocator, *project_godot.Document, []const u8) Error!void,
    doc: *project_godot.Document,
) Error!void {
    const json_text = try project_json.valueToJson(allocator, value);
    defer allocator.free(json_text);
    try apply_fn(allocator, doc, json_text);
    const summary = try std.fmt.allocPrint(allocator, "applied {s}", .{name});
    defer allocator.free(summary);
    try appendSection(allocator, out, name, summary);
}

fn applyInput(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_input.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
}

fn applySettings(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_settings.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
}

fn applyAutoload(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_autoload.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
}

fn applyPlugins(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_plugins.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
}

fn applyRendering(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_rendering.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
}

fn applyPhysics(allocator: std.mem.Allocator, doc: *project_godot.Document, json_text: []const u8) Error!void {
    var result = try project_physics.applyIntentJson(allocator, doc, json_text);
    defer result.deinit(allocator);
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

    var sections: std.ArrayList(SectionResult) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    var applied_any = false;

    if (root.object.get("input")) |value| {
        try applySubsection(allocator, &sections, "input", value, applyInput, doc);
        applied_any = true;
    }
    if (root.object.get("settings")) |value| {
        try applySubsection(allocator, &sections, "settings", value, applySettings, doc);
        applied_any = true;
    }
    if (root.object.get("autoload")) |value| {
        try applySubsection(allocator, &sections, "autoload", value, applyAutoload, doc);
        applied_any = true;
    }
    if (root.object.get("plugins")) |value| {
        try applySubsection(allocator, &sections, "plugins", value, applyPlugins, doc);
        applied_any = true;
    }
    if (root.object.get("rendering")) |value| {
        try applySubsection(allocator, &sections, "rendering", value, applyRendering, doc);
        applied_any = true;
    }
    if (root.object.get("physics")) |value| {
        try applySubsection(allocator, &sections, "physics", value, applyPhysics, doc);
        applied_any = true;
    }

    if (!applied_any) return error.MissingIntentSection;

    return .{ .sections = try sections.toOwnedSlice(allocator) };
}

pub fn buildSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    doc: *const project_godot.Document,
) Error!Summary {
    const project_name = if (project_settings.getSetting(doc, "application", "config/name")) |name|
        try allocator.dupe(u8, name)
    else
        null;
    errdefer if (project_name) |name| allocator.free(name);

    const main_scene = if (project_settings.getSetting(doc, "application", "run/main_scene")) |scene|
        try allocator.dupe(u8, scene)
    else
        null;
    errdefer if (main_scene) |scene| allocator.free(scene);

    const input_count: usize = if (doc.sectionIndex("input")) |index|
        doc.sections.items[index].entries.items.len
    else
        0;

    const autoload_count: usize = if (doc.sectionIndex("autoload")) |index|
        doc.sections.items[index].entries.items.len
    else
        0;

    const plugin_section_index = doc.sectionIndex("editor_plugins");
    const plugin_section: ?*const project_godot.Section = if (plugin_section_index) |index| &doc.sections.items[index] else null;
    const enabled_plugins = try project_plugins.parseEnabledPaths(allocator, plugin_section);
    defer {
        for (enabled_plugins) |path| allocator.free(path);
        allocator.free(enabled_plugins);
    }

    const rendering_method = if (project_settings.getSetting(doc, "rendering", "renderer/rendering_method")) |method|
        try allocator.dupe(u8, method)
    else
        null;

    const physics_engine_3d = if (project_settings.getSetting(doc, "physics", "3d/physics_engine")) |engine|
        try allocator.dupe(u8, engine)
    else
        null;

    _ = io;
    _ = project_root;

    return .{
        .project_name = project_name,
        .main_scene = main_scene,
        .input_action_count = input_count,
        .autoload_count = autoload_count,
        .enabled_plugin_count = enabled_plugins.len,
        .rendering_method = rendering_method,
        .physics_engine_3d = physics_engine_3d,
    };
}

test "unified apply runs multiple sections" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "settings": {
        \\    "application": { "run/main_scene": "res://main.tscn" }
        \\  },
        \\  "physics": {
        \\    "engine_3d": "Jolt Physics"
        \\  }
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.sections.len);
}
