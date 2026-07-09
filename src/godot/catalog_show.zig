//! Build merged `catalog show` output for project manifests and builtins.

const std = @import("std");
const catalog_scan = @import("catalog_scan.zig");
const catalog_builtins = @import("catalog_builtins.zig");
const gdscript_scan = @import("gdscript_scan.zig");
const document = @import("text_format/document.zig");
const node_tree = @import("node_tree.zig");
const scene_refs = @import("scene_refs.zig");
const project_config = @import("project_config.zig");
const property_line = @import("variant/property_line.zig");
const parse = @import("variant/parse.zig");
const uid_cache = @import("uid_cache.zig");

pub const MergedExport = struct {
    name: []const u8,
    type_hint: []const u8 = "",
    default_value: []const u8 = "",
    group: []const u8 = "",
    annotations: []const []const u8 = &.{},

    pub fn deinit(self: *const MergedExport, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type_hint);
        allocator.free(self.default_value);
        allocator.free(self.group);
        for (self.annotations) |annotation| allocator.free(annotation);
        allocator.free(self.annotations);
    }
};

pub const MergedSignal = struct {
    name: []const u8,
    args: []const u8 = "",
    doc: []const u8 = "",
    connect_example: []const u8 = "",
    doc_source: []const u8 = "",

    pub fn deinit(self: *const MergedSignal, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.args);
        allocator.free(self.doc);
        allocator.free(self.connect_example);
        allocator.free(self.doc_source);
    }
};

pub const SceneContext = struct {
    scene_res_path: []const u8,
    scene_filesystem_path: []const u8,
    root_node_name: []const u8 = "",
    root_node_type: []const u8 = "",
    root_script_res_path: []const u8 = "",
    root_script_filesystem_path: []const u8 = "",
    nodes: node_tree.NodeList,

    pub fn deinit(self: *SceneContext, allocator: std.mem.Allocator) void {
        allocator.free(self.scene_res_path);
        allocator.free(self.scene_filesystem_path);
        allocator.free(self.root_node_name);
        allocator.free(self.root_node_type);
        allocator.free(self.root_script_res_path);
        allocator.free(self.root_script_filesystem_path);
        self.nodes.deinit(allocator);
    }
};

pub const ShowResult = struct {
    id: []const u8,
    source: []const u8,
    manifest: ?catalog_scan.ManifestEntry = null,
    builtin: ?catalog_builtins.BuiltinEntry = null,
    scene: ?SceneContext = null,
    exports_source: []const u8 = "",
    exports: []MergedExport = &.{},
    signals: []MergedSignal = &.{},
    script_parse_complete: bool = true,

    pub fn deinit(self: *ShowResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source);
        allocator.free(self.exports_source);
        if (self.manifest) |*entry| entry.deinit(allocator);
        if (self.builtin) |entry| catalog_builtins.freeEntry(allocator, entry);
        if (self.scene) |*ctx| ctx.deinit(allocator);
        for (self.exports) |*item| item.deinit(allocator);
        allocator.free(self.exports);
        for (self.signals) |*item| item.deinit(allocator);
        allocator.free(self.signals);
    }
};

pub const ShowError = error{
    OutOfMemory,
    ProjectRootRequired,
    InvalidProjectRoot,
    CatalogEntryNotFound,
    InvalidBuiltinCatalog,
    Io,
};

pub fn showById(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    cache: ?*const uid_cache.Cache,
    id: []const u8,
) ShowError!ShowResult {
    if (catalog_builtins.isBuiltinId(id)) {
        const builtin = try catalog_builtins.findById(allocator, id) orelse return error.CatalogEntryNotFound;
        return try showBuiltin(allocator, builtin);
    }
    const root = project_root orelse return error.ProjectRootRequired;
    var scan = try catalog_scan.scanProject(allocator, io, root, cache);
    defer scan.deinit(allocator);
    const entry = findEntryById(scan.entries, id) orelse return error.CatalogEntryNotFound;
    return try showManifestEntry(allocator, io, root, cache, entry);
}

pub fn showManifestEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
    entry: *const catalog_scan.ManifestEntry,
) ShowError!ShowResult {
    _ = cache;
    var owned_entry = try cloneManifestEntry(allocator, entry);
    errdefer owned_entry.deinit(allocator);

    var scene_ctx: ?SceneContext = null;
    errdefer if (scene_ctx) |*ctx| ctx.deinit(allocator);

    var script_iface: ?gdscript_scan.ScriptInterface = null;
    errdefer if (script_iface) |*iface| iface.deinit(allocator);

    var discovered_script: ?[]const u8 = null;
    defer if (discovered_script) |path| allocator.free(path);

    const script_res_path: []const u8 = blk: {
        if (owned_entry.export_root_script.len > 0) break :blk owned_entry.export_root_script;
        if (owned_entry.scene.len == 0) break :blk "";

        const scene_fs_maybe = try project_config.resPathToFilesystem(allocator, project_root, owned_entry.scene);
        const scene_fs_path = scene_fs_maybe orelse break :blk "";
        defer allocator.free(scene_fs_path);

        var doc = document.parseFile(allocator, io, scene_fs_path) catch break :blk "";
        defer doc.deinit(allocator);

        var nodes = node_tree.collectNodes(allocator, &doc) catch break :blk "";
        defer nodes.deinit(allocator);

        const root_node = findSceneRoot(&nodes) orelse break :blk "";
        const root_section = doc.sections.items[root_node.section_index];
        const ext_id_owned = findScriptExtResourceId(allocator, &root_section) catch break :blk "";
        const ext_id = ext_id_owned orelse break :blk "";
        defer allocator.free(ext_id);

        var refs = scene_refs.collectExtResources(allocator, io, &doc, project_root) catch break :blk "";
        defer refs.deinit(allocator);

        const script_path = findExtResourcePath(&refs, ext_id) orelse break :blk "";
        discovered_script = try allocator.dupe(u8, script_path);
        scene_ctx = try buildSceneContext(
            allocator,
            project_root,
            owned_entry.scene,
            scene_fs_path,
            root_node,
            discovered_script.?,
            &nodes,
        );
        break :blk discovered_script.?;
    };

    const script_to_parse = if (owned_entry.export_root_script.len > 0)
        owned_entry.export_root_script
    else
        script_res_path;

    if (script_to_parse.len > 0) {
        const script_fs_maybe = project_config.resPathToFilesystem(allocator, project_root, script_to_parse) catch null;
        if (script_fs_maybe) |fs_path| {
            defer allocator.free(fs_path);
            const source = std.Io.Dir.cwd().readFileAlloc(io, fs_path, allocator, .unlimited) catch null;
            if (source) |text| {
                defer allocator.free(text);
                script_iface = gdscript_scan.parseScript(allocator, text) catch null;
            }
        }
    }

    var exports: []MergedExport = &.{};
    errdefer {
        for (exports) |*item| item.deinit(allocator);
        allocator.free(exports);
    }

    var signals: []MergedSignal = &.{};
    errdefer {
        for (signals) |*item| item.deinit(allocator);
        allocator.free(signals);
    }

    const script_parsed = script_iface != null;
    if (script_iface) |*iface| {
        exports = try mergeExports(allocator, iface.exports);
        signals = try mergeSignals(allocator, iface.signals, owned_entry.signal_docs);
        iface.deinit(allocator);
        script_iface = null;
    } else {
        signals = try mergeSignals(allocator, &.{}, owned_entry.signal_docs);
    }

    return .{
        .id = try allocator.dupe(u8, entry.id),
        .source = try allocator.dupe(u8, "project"),
        .manifest = owned_entry,
        .scene = scene_ctx,
        .exports_source = try allocator.dupe(u8, "gdscript_heuristic"),
        .exports = exports,
        .signals = signals,
        .script_parse_complete = script_parsed,
    };
}

fn showBuiltin(allocator: std.mem.Allocator, builtin: catalog_builtins.BuiltinEntry) ShowError!ShowResult {
    var signals: std.ArrayList(MergedSignal) = .empty;
    errdefer {
        for (signals.items) |*item| item.deinit(allocator);
        signals.deinit(allocator);
    }
    for (builtin.signals) |signal_doc| {
        try signals.append(allocator, .{
            .name = try allocator.dupe(u8, signal_doc.name),
            .doc = try allocator.dupe(u8, signal_doc.doc),
            .doc_source = try allocator.dupe(u8, "builtin"),
        });
    }

    return .{
        .id = try allocator.dupe(u8, builtin.id),
        .source = try allocator.dupe(u8, "builtin"),
        .builtin = builtin,
        .exports_source = try allocator.dupe(u8, "builtin"),
        .signals = try signals.toOwnedSlice(allocator),
    };
}

fn findEntryById(entries: []catalog_scan.ManifestEntry, id: []const u8) ?*catalog_scan.ManifestEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn cloneManifestEntry(allocator: std.mem.Allocator, entry: *const catalog_scan.ManifestEntry) ShowError!catalog_scan.ManifestEntry {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }
    for (entry.tags) |tag| try tags.append(allocator, try allocator.dupe(u8, tag));

    var related: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (related.items) |item| allocator.free(item);
        related.deinit(allocator);
    }
    for (entry.related_ids) |item| try related.append(allocator, try allocator.dupe(u8, item));

    var prefer: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefer.items) |item| allocator.free(item);
        prefer.deinit(allocator);
    }
    for (entry.prefer_over_ids) |item| try prefer.append(allocator, try allocator.dupe(u8, item));

    var signal_docs: std.ArrayList(catalog_scan.DocRow) = .empty;
    errdefer {
        for (signal_docs.items) |*row| row.deinit(allocator);
        signal_docs.deinit(allocator);
    }
    for (entry.signal_docs) |row| {
        try signal_docs.append(allocator, .{
            .name = try allocator.dupe(u8, row.name),
            .doc = try allocator.dupe(u8, row.doc),
            .connect_example = try allocator.dupe(u8, row.connect_example),
            .when_to_call = try allocator.dupe(u8, row.when_to_call),
        });
    }

    var function_docs: std.ArrayList(catalog_scan.DocRow) = .empty;
    errdefer {
        for (function_docs.items) |*row| row.deinit(allocator);
        function_docs.deinit(allocator);
    }
    for (entry.function_docs) |row| {
        try function_docs.append(allocator, .{
            .name = try allocator.dupe(u8, row.name),
            .doc = try allocator.dupe(u8, row.doc),
            .connect_example = try allocator.dupe(u8, row.connect_example),
            .when_to_call = try allocator.dupe(u8, row.when_to_call),
        });
    }

    var issues: std.ArrayList(catalog_scan.Issue) = .empty;
    errdefer {
        for (issues.items) |issue| {
            allocator.free(issue.code);
            allocator.free(issue.message);
        }
        issues.deinit(allocator);
    }
    for (entry.issues) |issue| {
        try issues.append(allocator, .{
            .severity = issue.severity,
            .code = try allocator.dupe(u8, issue.code),
            .message = try allocator.dupe(u8, issue.message),
        });
    }

    return .{
        .manifest_path = try allocator.dupe(u8, entry.manifest_path),
        .manifest_res_path = if (entry.manifest_res_path) |path| try allocator.dupe(u8, path) else null,
        .catalog_format_version = entry.catalog_format_version,
        .id = try allocator.dupe(u8, entry.id),
        .uid = try allocator.dupe(u8, entry.uid),
        .scene = try allocator.dupe(u8, entry.scene),
        .scene_uid = try allocator.dupe(u8, entry.scene_uid),
        .tags = try tags.toOwnedSlice(allocator),
        .summary = try allocator.dupe(u8, entry.summary),
        .when_to_use = try allocator.dupe(u8, entry.when_to_use),
        .when_not_to_use = try allocator.dupe(u8, entry.when_not_to_use),
        .related_ids = try related.toOwnedSlice(allocator),
        .prefer_over_ids = try prefer.toOwnedSlice(allocator),
        .notes = try allocator.dupe(u8, entry.notes),
        .export_root_script = try allocator.dupe(u8, entry.export_root_script),
        .signal_docs = try signal_docs.toOwnedSlice(allocator),
        .function_docs = try function_docs.toOwnedSlice(allocator),
        .issues = try issues.toOwnedSlice(allocator),
        .valid = entry.valid,
    };
}

fn findSceneRoot(nodes: *const node_tree.NodeList) ?*const node_tree.NodeInfo {
    for (nodes.nodes) |*node| {
        if (node.parent.len == 0) return node;
    }
    return null;
}

fn findScriptExtResourceId(allocator: std.mem.Allocator, section: *const document.Section) ShowError!?[]const u8 {
    for (section.properties.items) |prop| {
        const split = property_line.splitPropertyLine(prop.raw) orelse continue;
        if (!std.mem.eql(u8, split.name, "script")) continue;
        const value = parse.parsePropertyValue(allocator, split.value_text) catch continue;
        defer value.deinit(allocator);
        if (value.kind == .ext_resource) return try allocator.dupe(u8, value.string);
    }
    return null;
}

fn findExtResourcePath(refs: *const scene_refs.RefList, ext_id: []const u8) ?[]const u8 {
    for (refs.refs) |*ref| {
        if (std.mem.eql(u8, ref.id, ext_id)) return ref.path;
    }
    return null;
}

fn buildSceneContext(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    scene_res_path: []const u8,
    scene_fs_path: []const u8,
    root_node: *const node_tree.NodeInfo,
    script_res_path: []const u8,
    nodes: *const node_tree.NodeList,
) ShowError!SceneContext {
    var cloned_nodes: node_tree.NodeList = .{ .nodes = &[_]node_tree.NodeInfo{} };
    var node_items: std.ArrayList(node_tree.NodeInfo) = .empty;
    errdefer {
        for (node_items.items) |*node| node.deinit(allocator);
        node_items.deinit(allocator);
    }
    for (nodes.nodes) |*node| {
        try node_items.append(allocator, .{
            .name = try allocator.dupe(u8, node.name),
            .node_type = try allocator.dupe(u8, node.node_type),
            .parent = try allocator.dupe(u8, node.parent),
            .path = try allocator.dupe(u8, node.path),
            .section_line = node.section_line,
            .section_index = node.section_index,
            .unique_id = node.unique_id,
        });
    }
    cloned_nodes.nodes = try node_items.toOwnedSlice(allocator);

    const script_fs = project_config.resPathToFilesystem(allocator, project_root, script_res_path) catch null;
    errdefer if (script_fs) |path| allocator.free(path);

    return .{
        .scene_res_path = try allocator.dupe(u8, scene_res_path),
        .scene_filesystem_path = try allocator.dupe(u8, scene_fs_path),
        .root_node_name = try allocator.dupe(u8, root_node.name),
        .root_node_type = try allocator.dupe(u8, root_node.node_type),
        .root_script_res_path = try allocator.dupe(u8, script_res_path),
        .root_script_filesystem_path = if (script_fs) |path| path else try allocator.dupe(u8, ""),
        .nodes = cloned_nodes,
    };
}

fn mergeExports(allocator: std.mem.Allocator, parsed: []const gdscript_scan.ExportInfo) ShowError![]MergedExport {
    var out: std.ArrayList(MergedExport) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    for (parsed) |export_info| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, export_info.name),
            .type_hint = try allocator.dupe(u8, export_info.type_hint),
            .default_value = try allocator.dupe(u8, export_info.default_value),
            .group = try allocator.dupe(u8, export_info.group),
            .annotations = try dupStringSlice(allocator, export_info.annotations),
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn mergeSignals(
    allocator: std.mem.Allocator,
    parsed: []const gdscript_scan.SignalInfo,
    manifest_docs: []const catalog_scan.DocRow,
) ShowError![]MergedSignal {
    var out: std.ArrayList(MergedSignal) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (parsed) |signal_info| {
        const doc_row = findDocRow(manifest_docs, signal_info.name);
        const doc_source = if (doc_row != null and doc_row.?.doc.len > 0) "manifest" else "gdscript_heuristic";
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, signal_info.name),
            .args = try allocator.dupe(u8, signal_info.args),
            .doc = try allocator.dupe(u8, if (doc_row) |row| row.doc else ""),
            .connect_example = try allocator.dupe(u8, if (doc_row) |row| row.connect_example else ""),
            .doc_source = try allocator.dupe(u8, doc_source),
        });
        const seen_key = try allocator.dupe(u8, signal_info.name);
        try seen.put(seen_key, {});
    }

    for (manifest_docs) |row| {
        if (row.name.len == 0) continue;
        if (seen.contains(row.name)) continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, row.name),
            .doc = try allocator.dupe(u8, row.doc),
            .connect_example = try allocator.dupe(u8, row.connect_example),
            .doc_source = try allocator.dupe(u8, "manifest"),
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn findDocRow(rows: []const catalog_scan.DocRow, name: []const u8) ?*const catalog_scan.DocRow {
    for (rows) |*row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

fn dupStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ShowError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (items) |item| try out.append(allocator, try allocator.dupe(u8, item));
    return try out.toOwnedSlice(allocator);
}

test "show project fixture entry" {
    const allocator = std.testing.allocator;
    var shown = try showById(allocator, std.testing.io, "test_fixtures/project", null, "ui/button");
    defer shown.deinit(allocator);

    try std.testing.expectEqualStrings("project", shown.source);
    try std.testing.expect(shown.manifest != null);
    try std.testing.expect(shown.exports.len >= 1);
    try std.testing.expectEqualStrings("label_text", shown.exports[0].name);
    try std.testing.expect(shown.signals.len >= 1);
}

test "show builtin entry" {
    const allocator = std.testing.allocator;
    var shown = try showById(allocator, std.testing.io, null, null, "godot/ui/Button");
    defer shown.deinit(allocator);

    try std.testing.expectEqualStrings("builtin", shown.source);
    try std.testing.expect(shown.builtin != null);
    try std.testing.expect(shown.signals.len >= 1);
}
