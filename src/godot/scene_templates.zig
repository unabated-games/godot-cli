//! Built-in scene templates for agent scaffolding.

const std = @import("std");
const build_options = @import("build_options");
const document = @import("text_format/document.zig");
const save_prepare = @import("text_format/save_prepare.zig");
const writer = @import("text_format/writer.zig");
const node_tree = @import("node_tree.zig");
const scene_edit = @import("scene_edit.zig");
const variant = @import("variant/property_line.zig");

pub const Error = error{
    OutOfMemory,
    Io,
    TemplateNotFound,
    InvalidRenameSpec,
    InvalidPropertySpec,
    AmbiguousNodeName,
    NodeNotFound,
} || document.ParseError || document.EditError || save_prepare.PrepareError || node_tree.Error || scene_edit.Error;

pub const TemplateInfo = struct {
    id: []const u8,
    relative_path: []const u8,
    description: []const u8,
};

const builtins = [_]TemplateInfo{
    .{
        .id = "2d/character_body",
        .relative_path = "2d/character_body.tscn",
        .description = "CharacterBody2D with CollisionShape2D and Sprite2D children",
    },
    .{
        .id = "2d/top_down_player",
        .relative_path = "2d/top_down_player.tscn",
        .description = "CharacterBody2D with collision, sprite, and Camera2D for top-down games",
    },
    .{
        .id = "2d/camera_rig",
        .relative_path = "2d/camera_rig.tscn",
        .description = "Node2D root with a Camera2D child",
    },
    .{
        .id = "3d/static_body",
        .relative_path = "3d/static_body.tscn",
        .description = "StaticBody3D with CollisionShape3D and MeshInstance3D children",
    },
    .{
        .id = "ui/control_root",
        .relative_path = "ui/control_root.tscn",
        .description = "Control root with MarginContainer and VBoxContainer",
    },
};

pub const PropertySet = struct {
    path: []const u8,
    property: []const u8,
    value: []const u8,
};

pub const RenamePair = struct {
    old_name: []const u8,
    new_name: []const u8,
};

pub const CopyMutations = struct {
    renames: []const RenamePair = &.{},
    property_sets: []const PropertySet = &.{},
};

pub const TemplateShowData = struct {
    nodes: std.json.Array,
    sections: std.json.Array,
    section_count: usize,
    node_count: usize,
};

pub fn defaultTemplatesRoot() []const u8 {
    return build_options.templates_root;
}

/// Resolve templates directory: CLI flag, then `GODOT_CLI_TEMPLATES_ROOT`, then compile-time default.
pub fn resolveTemplatesRoot(flag_override: ?[]const u8) []const u8 {
    if (flag_override) |opt| return opt;
    if (std.c.getenv("GODOT_CLI_TEMPLATES_ROOT")) |env_root| return std.mem.span(env_root);
    return defaultTemplatesRoot();
}

pub fn listTemplates() []const TemplateInfo {
    return &builtins;
}

pub fn findTemplate(id: []const u8) ?TemplateInfo {
    for (builtins) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

pub fn resolveTemplatePath(
    allocator: std.mem.Allocator,
    templates_root: []const u8,
    template_id: []const u8,
) Error![]const u8 {
    const info = findTemplate(template_id) orelse return error.TemplateNotFound;
    return std.fs.path.join(allocator, &.{ templates_root, info.relative_path });
}

pub fn readTemplateBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    templates_root: []const u8,
    template_id: []const u8,
) Error![]const u8 {
    const path = try resolveTemplatePath(allocator, templates_root, template_id);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
}

pub fn parseRenameSpec(spec: []const u8) Error!RenamePair {
    const sep = std.mem.indexOf(u8, spec, ":") orelse return error.InvalidRenameSpec;
    if (sep == 0 or sep + 1 >= spec.len) return error.InvalidRenameSpec;
    return .{
        .old_name = spec[0..sep],
        .new_name = spec[sep + 1 ..],
    };
}

pub fn parseRenameList(allocator: std.mem.Allocator, text: []const u8) Error![]RenamePair {
    if (text.len == 0) return &.{};
    var items: std.ArrayList(RenamePair) = .empty;
    errdefer items.deinit(allocator);

    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const pair = try parseRenameSpec(trimmed);
        const old_copy = try allocator.dupe(u8, pair.old_name);
        errdefer allocator.free(old_copy);
        const new_copy = try allocator.dupe(u8, pair.new_name);
        try items.append(allocator, .{ .old_name = old_copy, .new_name = new_copy });
    }
    return try items.toOwnedSlice(allocator);
}

pub fn parsePropertySpec(spec: []const u8) Error!PropertySet {
    var pipe_parts: usize = 0;
    var pipe_split: [3][]const u8 = .{ "", "", "" };
    var pipe_iter = std.mem.splitScalar(u8, spec, '|');
    while (pipe_iter.next()) |part| {
        if (pipe_parts >= 3) break;
        pipe_split[pipe_parts] = std.mem.trim(u8, part, &std.ascii.whitespace);
        pipe_parts += 1;
    }
    if (pipe_parts == 3) {
        return .{
            .path = pipe_split[0],
            .property = pipe_split[1],
            .value = pipe_split[2],
        };
    }

    const eq = std.mem.indexOf(u8, spec, "=") orelse return error.InvalidPropertySpec;
    if (eq == 0 or eq + 1 >= spec.len) return error.InvalidPropertySpec;

    const left = std.mem.trim(u8, spec[0..eq], &std.ascii.whitespace);
    const value = std.mem.trim(u8, spec[eq + 1 ..], &std.ascii.whitespace);

    const slash = std.mem.lastIndexOf(u8, left, "/") orelse return error.InvalidPropertySpec;
    if (slash + 1 >= left.len) return error.InvalidPropertySpec;
    return .{
        .path = left[0..slash],
        .property = left[slash + 1 ..],
        .value = value,
    };
}

pub fn parsePropertyList(allocator: std.mem.Allocator, text: []const u8) Error![]PropertySet {
    if (text.len == 0) return &.{};
    var items: std.ArrayList(PropertySet) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.path);
            allocator.free(item.property);
            allocator.free(item.value);
        }
        items.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const parsed = try parsePropertySpec(trimmed);
        try items.append(allocator, .{
            .path = try allocator.dupe(u8, parsed.path),
            .property = try allocator.dupe(u8, parsed.property),
            .value = try allocator.dupe(u8, parsed.value),
        });
    }
    return try items.toOwnedSlice(allocator);
}

pub fn freeRenameList(allocator: std.mem.Allocator, pairs: []RenamePair) void {
    for (pairs) |pair| {
        allocator.free(pair.old_name);
        allocator.free(pair.new_name);
    }
    allocator.free(pairs);
}

pub fn freePropertyList(allocator: std.mem.Allocator, sets: []PropertySet) void {
    for (sets) |item| {
        allocator.free(item.path);
        allocator.free(item.property);
        allocator.free(item.value);
    }
    allocator.free(sets);
}

pub fn applyCopyMutations(allocator: std.mem.Allocator, doc: *document.Document, mutations: CopyMutations) Error!void {
    for (mutations.renames) |pair| {
        var list = try node_tree.collectNodes(allocator, doc);
        defer list.deinit(allocator);
        const node = try node_tree.findByName(&list, pair.old_name, null) orelse return error.NodeNotFound;
        _ = try scene_edit.renameNode(allocator, doc, node.path, pair.new_name);
    }

    for (mutations.property_sets) |set| {
        try scene_edit.setNodeProperty(allocator, doc, set.path, set.property, set.value);
    }
}

pub fn buildShowData(allocator: std.mem.Allocator, doc: *const document.Document, parse_properties: bool) Error!TemplateShowData {
    var list = try node_tree.collectNodes(allocator, doc);
    defer list.deinit(allocator);

    const nodes = try node_tree.nodesToJsonArray(allocator, list.nodes);

    var sections = std.json.Array.init(allocator);
    for (doc.sections.items) |section| {
        var fields: std.json.ObjectMap = .{};
        var it = section.header.fields.iterator();
        while (it.next()) |entry| {
            const value_json: std.json.Value = switch (entry.value_ptr.*) {
                .string => |s| .{ .string = s },
                .integer => |n| .{ .integer = n },
                .float => |f| .{ .float = f },
                .bool => |b| .{ .bool = b },
            };
            try fields.put(allocator, entry.key_ptr.*, value_json);
        }

        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "line", .{ .integer = @intCast(section.line) });
        try row.put(allocator, "name", .{ .string = section.header.name });
        try row.put(allocator, "fields", .{ .object = fields });
        try row.put(allocator, "property_count", .{ .integer = @intCast(section.properties.items.len) });
        if (parse_properties) {
            const properties = try variant.buildPropertiesJson(allocator, section.properties.items);
            try row.put(allocator, "properties", .{ .array = properties });
        }
        try sections.append(.{ .object = row });
    }

    return .{
        .nodes = nodes,
        .sections = sections,
        .section_count = doc.sections.items.len,
        .node_count = list.nodes.len,
    };
}

pub fn copyTemplateToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    templates_root: []const u8,
    template_id: []const u8,
    output_path: []const u8,
    prepare: ?save_prepare.SaveOptions,
    mutations: CopyMutations,
) Error!void {
    const bytes = try readTemplateBytes(allocator, io, templates_root, template_id);
    defer allocator.free(bytes);

    var doc = try document.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    try applyCopyMutations(allocator, &doc, mutations);

    if (prepare) |options| {
        try save_prepare.prepareDocument(allocator, &doc, options);
    }

    const written = writer.writeDocument(allocator, &doc) catch return error.OutOfMemory;
    defer allocator.free(written);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = written }) catch return error.Io;
}

test "list built-in templates" {
    try std.testing.expectEqual(@as(usize, 5), listTemplates().len);
    try std.testing.expect(findTemplate("2d/character_body") != null);
    try std.testing.expect(findTemplate("2d/top_down_player") != null);
    try std.testing.expect(findTemplate("missing") == null);
}

test "parse rename and property specs" {
    const rename = try parseRenameSpec("Player:Hero");
    try std.testing.expectEqualStrings("Player", rename.old_name);
    try std.testing.expectEqualStrings("Hero", rename.new_name);

    const slash_prop = try parsePropertySpec("/root/Player/Collision/shape=SubResource(\"x\")");
    try std.testing.expectEqualStrings("/root/Player/Collision", slash_prop.path);
    try std.testing.expectEqualStrings("shape", slash_prop.property);

    const pipe_prop = try parsePropertySpec("/root/Hero/Sprite|texture|ExtResource(\"1_tex\")");
    try std.testing.expectEqualStrings("/root/Hero/Sprite", pipe_prop.path);
    try std.testing.expectEqualStrings("texture", pipe_prop.property);
}

test "apply copy mutations renames and sets properties" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Player" type="CharacterBody2D"]
        \\visible = true
        \\
        \\[node name="Sprite" type="Sprite2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const renames = [_]RenamePair{.{ .old_name = "Player", .new_name = "Hero" }};
    const sets = [_]PropertySet{.{ .path = "/root/Hero", .property = "visible", .value = "false" }};

    try applyCopyMutations(allocator, &doc, .{
        .renames = &renames,
        .property_sets = &sets,
    });

    var list = try node_tree.collectNodes(allocator, &doc);
    defer list.deinit(allocator);
    try std.testing.expect(node_tree.findByPath(&list, "/root/Hero") != null);
    try std.testing.expect(node_tree.findByPath(&list, "/root/Hero/Sprite") != null);

    const section_index = try scene_edit.findNodeSectionIndex(allocator, &doc, "/root/Hero");
    const section = doc.sections.items[section_index];
    try std.testing.expectEqualStrings("visible = false", section.properties.items[0].raw);
}

test "build show data includes nodes and sections" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Child" type="Sprite2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const show = try buildShowData(allocator, &doc, false);
    try std.testing.expectEqual(@as(usize, 2), show.node_count);
    try std.testing.expectEqual(@as(usize, 3), show.section_count);
    try std.testing.expectEqual(@as(usize, 2), show.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 3), show.sections.items.len);
}
