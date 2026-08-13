//! Scaffold and update `*.manifest.json` catalog manifests.
//!
//! Replaces the authoring half of the Godot editor addon. The signal rows the
//! addon made you type by hand are scaffolded here from the scene's root script,
//! because the CLI already parses GDScript for `catalog show`.

const std = @import("std");
const document = @import("text_format/document.zig");
const gdscript_scan = @import("gdscript_scan.zig");
const node_tree = @import("node_tree.zig");
const parse = @import("variant/parse.zig");
const project_config = @import("project_config.zig");
const property_line = @import("variant/property_line.zig");
const scene_refs = @import("scene_refs.zig");
const catalog_scan = @import("catalog_scan.zig");
const io_util = @import("../io_util.zig");

pub const Error = error{
    OutOfMemory,
    Io,
    InvalidProjectRoot,
    SceneNotFound,
    InvalidScenePath,
    ManifestExists,
    ManifestNotFound,
    InvalidManifest,
};

pub const Options = struct {
    /// `res://` path of the scene being described.
    scene: []const u8,
    id: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    when_to_use: ?[]const u8 = null,
    when_not_to_use: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    related_ids: []const []const u8 = &.{},
    /// Update an existing manifest in place instead of refusing to overwrite.
    update: bool = false,
    /// Explicit output path; defaults to `<scene dir>/<scene name>.manifest.json`.
    output: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const Result = struct {
    manifest_path: []const u8,
    manifest_res_path: []const u8,
    id: []const u8,
    scene: []const u8,
    scene_uid: []const u8,
    signals_scaffolded: usize = 0,
    updated: bool = false,
    json: []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        allocator.free(self.manifest_res_path);
        allocator.free(self.id);
        allocator.free(self.scene);
        allocator.free(self.scene_uid);
        allocator.free(self.json);
    }
};

/// Godot catalog id from a scene path: strip `res://`, drop the extension,
/// lowercase. `res://ui/button/button.tscn` becomes `ui/button/button`.
pub fn suggestIdFromScenePath(allocator: std.mem.Allocator, scene: []const u8) Error![]const u8 {
    var path = scene;
    if (std.mem.startsWith(u8, path, "res://")) path = path["res://".len..];
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        if (std.ascii.eqlIgnoreCase(path[dot..], ".tscn")) path = path[0..dot];
    }
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Default manifest path for a scene: sibling file, `.tscn` swapped for
/// `.manifest.json`.
pub fn defaultManifestPath(allocator: std.mem.Allocator, scene_fs_path: []const u8) Error![]const u8 {
    var stem = scene_fs_path;
    if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| {
        if (std.ascii.eqlIgnoreCase(stem[dot..], ".tscn")) stem = stem[0..dot];
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, catalog_scan.manifest_json_suffix });
}

const ExistingProse = struct {
    summary: []const u8 = "",
    when_to_use: []const u8 = "",
    when_not_to_use: []const u8 = "",
    notes: []const u8 = "",
    tags: []const []const u8 = &.{},
    related_ids: []const []const u8 = &.{},
    prefer_over_ids: []const []const u8 = &.{},
    export_root_script: []const u8 = "",
    signals: []catalog_scan.DocRow = &.{},
    functions: []catalog_scan.DocRow = &.{},

    fn deinit(self: *ExistingProse, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.when_to_use);
        allocator.free(self.when_not_to_use);
        allocator.free(self.notes);
        for (self.tags) |item| allocator.free(item);
        allocator.free(self.tags);
        for (self.related_ids) |item| allocator.free(item);
        allocator.free(self.related_ids);
        for (self.prefer_over_ids) |item| allocator.free(item);
        allocator.free(self.prefer_over_ids);
        allocator.free(self.export_root_script);
        for (self.signals) |*row| row.deinit(allocator);
        allocator.free(self.signals);
        for (self.functions) |*row| row.deinit(allocator);
        allocator.free(self.functions);
    }
};

pub fn addManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    options: Options,
) Error!Result {
    if (!std.mem.startsWith(u8, options.scene, "res://")) return error.InvalidScenePath;

    const scene_fs_maybe = project_config.resPathToFilesystem(allocator, project_root, options.scene) catch
        return error.InvalidScenePath;
    const scene_fs_path = scene_fs_maybe orelse return error.InvalidScenePath;
    defer allocator.free(scene_fs_path);

    std.Io.Dir.cwd().access(io, scene_fs_path, .{}) catch return error.SceneNotFound;

    const manifest_path = if (options.output) |out|
        try allocator.dupe(u8, out)
    else
        try defaultManifestPath(allocator, scene_fs_path);
    errdefer allocator.free(manifest_path);

    const exists = blk: {
        std.Io.Dir.cwd().access(io, manifest_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists and !options.update) return error.ManifestExists;
    if (!exists and options.update) return error.ManifestNotFound;

    // Everything a human wrote is preserved across an update; only derived
    // fields and newly declared signals change.
    var prose: ExistingProse = .{};
    defer prose.deinit(allocator);
    if (exists) prose = try readExistingProse(allocator, io, manifest_path);

    const id = if (options.id) |value|
        try allocator.dupe(u8, value)
    else if (exists)
        try readExistingId(allocator, io, manifest_path, options.scene)
    else
        try suggestIdFromScenePath(allocator, options.scene);
    errdefer allocator.free(id);

    const scene_uid = try readSceneHeaderUid(allocator, io, scene_fs_path);
    errdefer allocator.free(scene_uid);

    const signals = try scaffoldSignals(allocator, io, project_root, options.scene, prose.signals);
    errdefer {
        for (signals) |*row| row.deinit(allocator);
        allocator.free(signals);
    }
    const scaffolded = countBlankDocs(signals);

    const json = try renderManifest(allocator, .{
        .id = id,
        .scene = options.scene,
        .scene_uid = scene_uid,
        .tags = if (options.tags.len > 0) options.tags else prose.tags,
        .summary = options.summary orelse prose.summary,
        .when_to_use = options.when_to_use orelse prose.when_to_use,
        .when_not_to_use = options.when_not_to_use orelse prose.when_not_to_use,
        .notes = options.notes orelse prose.notes,
        .related_ids = if (options.related_ids.len > 0) options.related_ids else prose.related_ids,
        .prefer_over_ids = prose.prefer_over_ids,
        .export_root_script = prose.export_root_script,
        .signals = signals,
        .functions = prose.functions,
    });
    errdefer allocator.free(json);

    if (!options.dry_run) {
        io_util.writeFileAtomic(io, manifest_path, json) catch return error.Io;
    }

    const manifest_res = (project_config.filesystemToResPath(allocator, project_root, manifest_path) catch null) orelse
        try allocator.dupe(u8, "");

    for (signals) |*row| row.deinit(allocator);
    allocator.free(signals);

    return .{
        .manifest_path = manifest_path,
        .manifest_res_path = manifest_res,
        .id = id,
        .scene = try allocator.dupe(u8, options.scene),
        .scene_uid = scene_uid,
        .signals_scaffolded = scaffolded,
        .updated = exists,
        .json = json,
    };
}

const RenderInput = struct {
    id: []const u8,
    scene: []const u8,
    scene_uid: []const u8,
    tags: []const []const u8,
    summary: []const u8,
    when_to_use: []const u8,
    when_not_to_use: []const u8,
    notes: []const u8,
    related_ids: []const []const u8,
    prefer_over_ids: []const []const u8,
    export_root_script: []const u8,
    signals: []const catalog_scan.DocRow,
    functions: []const catalog_scan.DocRow,
};

/// Render a manifest.
///
/// Empty optional fields are omitted rather than written as `""`, so a
/// hand-edited manifest stays small and diffs show only what was actually said.
/// Required fields are always present, even when empty, so the shape is obvious
/// to whoever edits it next.
fn renderManifest(allocator: std.mem.Allocator, input: RenderInput) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendFmt(allocator, &out, "{{\n  \"catalog_format_version\": {d},\n", .{catalog_scan.catalog_format_version_json});
    try writeStringField(allocator, &out, "id", input.id, 1, true);
    try writeStringField(allocator, &out, "scene", input.scene, 1, true);
    if (input.scene_uid.len > 0) try writeStringField(allocator, &out, "scene_uid", input.scene_uid, 1, true);
    try writeStringArrayField(allocator, &out, "tags", input.tags, true);

    try writeStringField(allocator, &out, "summary", input.summary, 1, true);
    try writeStringField(allocator, &out, "when_to_use", input.when_to_use, 1, true);
    if (input.when_not_to_use.len > 0) try writeStringField(allocator, &out, "when_not_to_use", input.when_not_to_use, 1, true);
    if (input.notes.len > 0) try writeStringField(allocator, &out, "notes", input.notes, 1, true);
    if (input.related_ids.len > 0) try writeStringArrayField(allocator, &out, "related_ids", input.related_ids, true);
    if (input.prefer_over_ids.len > 0) try writeStringArrayField(allocator, &out, "prefer_over_ids", input.prefer_over_ids, true);
    if (input.export_root_script.len > 0) try writeStringField(allocator, &out, "export_root_script", input.export_root_script, 1, true);

    try writeDocRows(allocator, &out, "signals", input.signals, true, input.functions.len > 0);
    if (input.functions.len > 0) {
        try writeDocRows(allocator, &out, "functions", input.functions, false, false);
    }

    try out.appendSlice(allocator, "}\n");
    return try out.toOwnedSlice(allocator);
}

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

/// Emit a JSON string literal, escaping via the standard encoder rather than by
/// hand — manifest prose routinely contains quotes and newlines.
fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) Error!void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    std.json.Stringify.value(value, .{}, &buf.writer) catch return error.OutOfMemory;
    try out.appendSlice(allocator, buf.written());
}

fn writeStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
    indent: usize,
    comma: bool,
) Error!void {
    for (0..indent) |_| try out.appendSlice(allocator, "  ");
    try appendFmt(allocator, out, "\"{s}\": ", .{name});
    try appendJsonString(allocator, out, value);
    try out.appendSlice(allocator, if (comma) ",\n" else "\n");
}

fn writeStringArrayField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    values: []const []const u8,
    comma: bool,
) Error!void {
    try appendFmt(allocator, out, "  \"{s}\": [", .{name});
    for (values, 0..) |value, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try appendJsonString(allocator, out, value);
    }
    try out.appendSlice(allocator, if (comma) "],\n" else "]\n");
}

fn writeDocRows(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    rows: []const catalog_scan.DocRow,
    is_signal: bool,
    comma: bool,
) Error!void {
    if (rows.len == 0) {
        try appendFmt(allocator, out, "  \"{s}\": []{s}", .{ name, if (comma) ",\n" else "\n" });
        return;
    }
    try appendFmt(allocator, out, "  \"{s}\": [\n", .{name});
    for (rows, 0..) |row, i| {
        try out.appendSlice(allocator, "    {\n");
        try writeStringField(allocator, out, "name", row.name, 3, true);
        try writeStringField(allocator, out, "doc", row.doc, 3, true);
        if (is_signal) {
            try writeStringField(allocator, out, "connect_example", row.connect_example, 3, false);
        } else {
            try writeStringField(allocator, out, "when_to_call", row.when_to_call, 3, false);
        }
        try out.appendSlice(allocator, if (i + 1 < rows.len) "    },\n" else "    }\n");
    }
    try out.appendSlice(allocator, if (comma) "  ],\n" else "  ]\n");
}

/// Signal rows for the scene's root script, preserving any prose already written
/// against a signal of the same name and dropping rows for signals that no
/// longer exist.
fn scaffoldSignals(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    scene_res_path: []const u8,
    existing: []const catalog_scan.DocRow,
) Error![]catalog_scan.DocRow {
    var rows: std.ArrayList(catalog_scan.DocRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    const script_res = try findRootScript(allocator, io, project_root, scene_res_path);
    defer if (script_res) |path| allocator.free(path);

    if (script_res) |res_path| {
        const script_fs_maybe = project_config.resPathToFilesystem(allocator, project_root, res_path) catch null;
        if (script_fs_maybe) |fs_path| {
            defer allocator.free(fs_path);
            const source = std.Io.Dir.cwd().readFileAlloc(io, fs_path, allocator, .unlimited) catch null;
            if (source) |text| {
                defer allocator.free(text);
                var iface = gdscript_scan.parseScript(allocator, text) catch
                    gdscript_scan.ScriptInterface{};
                defer iface.deinit(allocator);

                for (iface.signals) |signal| {
                    const prior = findRow(existing, signal.name);
                    try rows.append(allocator, .{
                        .name = try allocator.dupe(u8, signal.name),
                        .doc = try allocator.dupe(u8, if (prior) |p| p.doc else ""),
                        .connect_example = try allocator.dupe(u8, if (prior) |p| p.connect_example else ""),
                        .when_to_call = try allocator.dupe(u8, ""),
                    });
                }
            }
        }
    }

    // A scene with no script keeps whatever was documented by hand.
    if (rows.items.len == 0) {
        for (existing) |row| {
            try rows.append(allocator, .{
                .name = try allocator.dupe(u8, row.name),
                .doc = try allocator.dupe(u8, row.doc),
                .connect_example = try allocator.dupe(u8, row.connect_example),
                .when_to_call = try allocator.dupe(u8, row.when_to_call),
            });
        }
    }

    return try rows.toOwnedSlice(allocator);
}

fn findRow(rows: []const catalog_scan.DocRow, name: []const u8) ?catalog_scan.DocRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

fn countBlankDocs(rows: []const catalog_scan.DocRow) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (row.doc.len == 0) count += 1;
    }
    return count;
}

fn findRootScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    scene_res_path: []const u8,
) Error!?[]const u8 {
    const scene_fs_maybe = project_config.resPathToFilesystem(allocator, project_root, scene_res_path) catch return null;
    const scene_fs = scene_fs_maybe orelse return null;
    defer allocator.free(scene_fs);

    var doc = document.parseFile(allocator, io, scene_fs) catch return null;
    defer doc.deinit(allocator);

    var nodes = node_tree.collectNodes(allocator, &doc) catch return null;
    defer nodes.deinit(allocator);
    if (nodes.nodes.len == 0) return null;

    const root_section = doc.sections.items[nodes.nodes[0].section_index];
    const ext_id = (try findScriptExtResourceId(allocator, &root_section)) orelse return null;
    defer allocator.free(ext_id);

    var refs = scene_refs.collectExtResources(allocator, io, &doc, project_root) catch return null;
    defer refs.deinit(allocator);

    for (refs.refs) |*ref| {
        if (std.mem.eql(u8, ref.id, ext_id)) return try allocator.dupe(u8, ref.path);
    }
    return null;
}

fn findScriptExtResourceId(
    allocator: std.mem.Allocator,
    section: *const document.Section,
) Error!?[]const u8 {
    for (section.properties.items) |prop| {
        const split = property_line.splitPropertyLine(prop.raw) orelse continue;
        if (!std.mem.eql(u8, split.name, "script")) continue;
        const value = parse.parsePropertyValue(allocator, split.value_text) catch continue;
        defer value.deinit(allocator);
        if (value.kind == .ext_resource) return try allocator.dupe(u8, value.string);
    }
    return null;
}

fn readSceneHeaderUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_fs_path: []const u8,
) Error![]const u8 {
    var doc = document.parseFile(allocator, io, scene_fs_path) catch return try allocator.dupe(u8, "");
    defer doc.deinit(allocator);
    if (doc.sections.items.len == 0) return try allocator.dupe(u8, "");
    const header = doc.sections.items[0].header;
    if (!std.mem.eql(u8, header.name, "gd_scene")) return try allocator.dupe(u8, "");
    const uid = header.getString("uid") orelse return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, uid);
}

fn readExistingProse(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
) Error!ExistingProse {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch
        return error.InvalidManifest;
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.InvalidManifest;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidManifest,
    };

    var prose: ExistingProse = .{};
    errdefer prose.deinit(allocator);
    prose.summary = try dupJsonString(allocator, root, "summary");
    prose.when_to_use = try dupJsonString(allocator, root, "when_to_use");
    prose.when_not_to_use = try dupJsonString(allocator, root, "when_not_to_use");
    prose.notes = try dupJsonString(allocator, root, "notes");
    prose.export_root_script = try dupJsonString(allocator, root, "export_root_script");
    prose.tags = try dupJsonStringList(allocator, root, "tags");
    prose.related_ids = try dupJsonStringList(allocator, root, "related_ids");
    prose.prefer_over_ids = try dupJsonStringList(allocator, root, "prefer_over_ids");
    prose.signals = try dupJsonDocRows(allocator, root, "signals");
    prose.functions = try dupJsonDocRows(allocator, root, "functions");
    return prose;
}

fn readExistingId(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
    scene: []const u8,
) Error![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch
        return suggestIdFromScenePath(allocator, scene);
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return suggestIdFromScenePath(allocator, scene);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return suggestIdFromScenePath(allocator, scene),
    };
    const existing = try dupJsonString(allocator, root, "id");
    if (existing.len > 0) return existing;
    allocator.free(existing);
    return suggestIdFromScenePath(allocator, scene);
}

fn dupJsonString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) Error![]const u8 {
    const value = obj.get(key) orelse return try allocator.dupe(u8, "");
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    };
}

fn dupJsonStringList(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) Error![]const []const u8 {
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

fn dupJsonDocRows(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) Error![]catalog_scan.DocRow {
    const value = obj.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var rows: std.ArrayList(catalog_scan.DocRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    for (array.items) |item| {
        const row_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var row: catalog_scan.DocRow = .{
            .name = try dupJsonString(allocator, row_obj, "name"),
        };
        errdefer row.deinit(allocator);
        row.doc = try dupJsonString(allocator, row_obj, "doc");
        row.connect_example = try dupJsonString(allocator, row_obj, "connect_example");
        row.when_to_call = try dupJsonString(allocator, row_obj, "when_to_call");
        try rows.append(allocator, row);
    }
    return try rows.toOwnedSlice(allocator);
}

test "suggest id from scene path" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { scene: []const u8, want: []const u8 }{
        .{ .scene = "res://ui/button/button.tscn", .want = "ui/button/button" },
        .{ .scene = "res://UI/Button.TSCN", .want = "ui/button" },
        .{ .scene = "res://main.tscn", .want = "main" },
    };
    for (cases) |case| {
        const got = try suggestIdFromScenePath(allocator, case.scene);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "default manifest path sits beside the scene" {
    const allocator = std.testing.allocator;
    const got = try defaultManifestPath(allocator, "/proj/ui/button/button.tscn");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("/proj/ui/button/button.manifest.json", got);
}

test "rendered manifest omits empty optionals and round-trips" {
    const allocator = std.testing.allocator;
    const signals = [_]catalog_scan.DocRow{.{
        .name = "button_pressed",
        .doc = "Emitted on click.",
        .connect_example = "",
        .when_to_call = "",
    }};
    const tags = [_][]const u8{ "ui", "button" };

    const json = try renderManifest(allocator, .{
        .id = "ui/button",
        .scene = "res://ui/button/button.tscn",
        .scene_uid = "uid://byhqeak2spha2",
        .tags = &tags,
        .summary = "A button",
        .when_to_use = "Player-facing UI",
        .when_not_to_use = "",
        .notes = "",
        .related_ids = &.{},
        .prefer_over_ids = &.{},
        .export_root_script = "",
        .signals = &signals,
        .functions = &.{},
    });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"when_not_to_use\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"notes\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"related_ids\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), root.get("catalog_format_version").?.integer);
    try std.testing.expectEqualStrings("ui/button", root.get("id").?.string);
    try std.testing.expectEqualStrings("button_pressed", root.get("signals").?.array.items[0].object.get("name").?.string);
}

test "rendered manifest escapes quotes and newlines" {
    const allocator = std.testing.allocator;
    const json = try renderManifest(allocator, .{
        .id = "ui/quote",
        .scene = "res://ui/quote.tscn",
        .scene_uid = "",
        .tags = &.{},
        .summary = "Say \"hello\"\nthen stop",
        .when_to_use = "",
        .when_not_to_use = "",
        .notes = "",
        .related_ids = &.{},
        .prefer_over_ids = &.{},
        .export_root_script = "",
        .signals = &.{},
        .functions = &.{},
    });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Say \"hello\"\nthen stop", parsed.value.object.get("summary").?.string);
}
