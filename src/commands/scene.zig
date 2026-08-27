const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const resource_uid = @import("../godot/resource_uid.zig");
const uid_cache = @import("../godot/uid_cache.zig");
const text_format = @import("../godot/text_format/root.zig");
const id_validate = @import("../godot/id_validate.zig");
const id_session = @import("../godot/id_session.zig");
const project_config = @import("../godot/project_config.zig");
const variant = @import("../godot/variant/root.zig");
const node_tree = @import("../godot/node_tree.zig");
const scene_edit = @import("../godot/scene_edit.zig");
const scene_refs = @import("../godot/scene_refs.zig");
const scene_resources = @import("../godot/scene_resources.zig");
const scene_instance = @import("../godot/scene_instance.zig");
const resource_uid_lookup = @import("../godot/resource_uid_lookup.zig");
const scene_patch = @import("../godot/scene_patch.zig");
const scene_plan = @import("../godot/scene_plan.zig");
const scene_diff = @import("../godot/scene_diff.zig");
const scene_undo = @import("../godot/scene_undo.zig");
const scene_templates = @import("../godot/scene_templates.zig");
const catalog_scan = @import("../godot/catalog_scan.zig");
const catalog_builtins = @import("../godot/catalog_builtins.zig");
const io_util = @import("../io_util.zig");

const ValidateSetup = struct {
    ctx: id_validate.ValidateContext,
    owned_project_name: ?[]u8 = null,
    owned_resource_path: ?[]u8 = null,
    owned_cache: ?uid_cache.Cache = null,

    pub fn deinit(self: *ValidateSetup, allocator: std.mem.Allocator) void {
        if (self.owned_project_name) |name| allocator.free(name);
        if (self.owned_resource_path) |path| allocator.free(path);
        if (self.owned_cache) |*cache| cache.deinit(allocator);
    }

    pub fn init(cli: *const app_mod.App, inv: *const spec.Invocation, path: []const u8) !ValidateSetup {
        var setup: ValidateSetup = .{ .ctx = .{} };

        const root = projectRootFrom(inv) orelse return setup;
        setup.ctx.project_root = root;
        setup.ctx.io = cli.io;
        setup.ctx.file_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, path, cli.allocator, .unlimited) catch null;

        if (try loadCacheOptional(cli, inv)) |loaded| {
            setup.owned_cache = loaded;
            setup.ctx.cache = &setup.owned_cache.?;
        }

        setup.owned_project_name = project_config.readProjectName(cli.allocator, cli.io, root) catch null;
        setup.ctx.project_name = setup.owned_project_name;

        if (setup.owned_project_name != null) {
            setup.owned_resource_path = try project_config.filesystemToResPath(cli.allocator, root, path);
            setup.ctx.resource_path = setup.owned_resource_path;
        }

        return setup;
    }
};

const PreparedSave = struct {
    options: ?text_format.save_prepare.SaveOptions,
    session: ?*id_session.Session = null,
    session_path: ?[]const u8 = null,
    seed_path_owned: ?[]const u8 = null,

    pub fn deinit(self: *PreparedSave, allocator: std.mem.Allocator) void {
        if (self.seed_path_owned) |path| allocator.free(path);
        if (self.session) |session| {
            session.deinit(allocator);
            allocator.destroy(session);
        }
        if (self.session_path) |path| allocator.free(path);
    }

    /// The id session cache only makes ext_resource ids reproducible across
    /// runs; the scene has already been written by the time this is called.
    /// Failing the command here would report a successful edit as an error and
    /// leave the caller unsure whether the file changed — so a cache that
    /// cannot be written is dropped instead.
    pub fn persistSession(self: *PreparedSave, allocator: std.mem.Allocator) !void {
        if (self.session_path) |path| {
            if (self.session) |session| session.saveToFile(path) catch {};
        }
        _ = allocator;
    }
};

/// `options` with one long name removed, for a command that redefines a shared
/// option with different semantics.
fn withoutOption(comptime options: []const spec.OptionSpec, comptime long: []const u8) []const spec.OptionSpec {
    comptime {
        var kept: []const spec.OptionSpec = &.{};
        for (options) |opt| {
            if (!std.mem.eql(u8, opt.long, long)) kept = kept ++ [_]spec.OptionSpec{opt};
        }
        return kept;
    }
}

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn projectRootFrom(inv: *const spec.Invocation) ?[]const u8 {
    return inv.getOption("project-root");
}

fn saveSeedPath(cli: *const app_mod.App, inv: *const spec.Invocation, output_path: []const u8) ![]const u8 {
    if (inv.getOption("resource-path")) |path| {
        return try cli.allocator.dupe(u8, path);
    }
    if (projectRootFrom(inv)) |root| {
        if (try project_config.filesystemToResPath(cli.allocator, root, output_path)) |res| {
            return res;
        }
    }
    return try cli.allocator.dupe(u8, output_path);
}

fn prepareSaveOptions(cli: *const app_mod.App, inv: *const spec.Invocation, output_path: []const u8) !PreparedSave {
    if (inv.flag("no-prepare-save")) return .{ .options = null };

    const seed_path = try saveSeedPath(cli, inv, output_path);
    var prepared: PreparedSave = .{
        .options = .{
            .seed_path = seed_path,
            .godot_save_format = inv.flag("godot-save-format"),
        },
        .seed_path_owned = seed_path,
    };

    if (!inv.flag("no-id-session")) {
        const session_path = if (inv.getOption("id-session")) |path|
            try cli.allocator.dupe(u8, path)
        else if (projectRootFrom(inv)) |root|
            try id_session.Session.defaultPath(cli.allocator, root)
        else
            null;

        if (session_path) |path| {
            prepared.session_path = path;
            const session = try cli.allocator.create(id_session.Session);
            session.* = id_session.Session.loadFromFile(cli.allocator, path) catch id_session.Session.init(cli.allocator);
            prepared.session = session;
            if (prepared.options) |*options| {
                options.id_session = session;
            }
        }
    }

    return prepared;
}

fn writeWithPrepare(cli: *const app_mod.App, inv: *const spec.Invocation, output_path: []const u8, doc: *text_format.document.Document) !void {
    var prepare = try prepareSaveOptions(cli, inv, output_path);
    defer prepare.deinit(cli.allocator);
    try text_format.writer.writeFile(cli.allocator, output_path, doc, prepare.options);
    if (!inv.flag("dry-run")) {
        try prepare.persistSession(cli.allocator);
    }
}

fn loadCacheOptional(cli: *const app_mod.App, inv: *const spec.Invocation) !?uid_cache.Cache {
    const root = projectRootFrom(inv) orelse return null;
    const cache_path = try uid_cache.defaultCachePath(cli.allocator, root);
    defer cli.allocator.free(cache_path);
    return uid_cache.loadFromFile(cli.allocator, cli.io, cache_path) catch |err| switch (err) {
        error.Io => null,
        else => return err,
    };
}

fn buildIssuesJson(cli: *const app_mod.App, report: *const id_validate.Report) !std.json.Array {
    var issues = std.json.Array.init(cli.allocator);
    for (report.issues.items) |issue| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "severity", .{ .string = @tagName(issue.severity) });
        try row.put(cli.allocator, "kind", .{ .string = issue.kind });
        try row.put(cli.allocator, "message", .{ .string = issue.message });
        if (issue.line) |line| {
            try row.put(cli.allocator, "line", .{ .integer = @intCast(line) });
        }
        try issues.append(.{ .object = row });
    }
    return issues;
}

fn validateHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];

    const doc = try text_format.document.parseFile(cli.allocator, cli.io, path);
    var setup = try ValidateSetup.init(cli, inv, path);
    defer setup.deinit(cli.allocator);

    const report = try id_validate.validateDocument(cli.allocator, &doc, setup.ctx);

    const issues = try buildIssuesJson(cli, &report);
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "issues", .{ .array = issues });
    try data.put(cli.allocator, "error_count", .{ .integer = @intCast(countErrors(&report)) });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{s}: {d} issue(s), {d} error(s)",
        .{ kind, report.issues.items.len, countErrors(&report) },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    if (id_validate.hasErrors(&report)) {
        return .{
            .data = .{ .object = data },
            .messages = &.{},
            .exit_code = .failure,
        };
    }

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn countErrors(report: *const id_validate.Report) usize {
    var total: usize = 0;
    for (report.issues.items) |issue| {
        if (issue.severity == .err) total += 1;
    }
    return total;
}

fn formatPropertyValueForWrite(
    allocator: std.mem.Allocator,
    property_value: []const u8,
    raw: bool,
) ![]const u8 {
    if (raw) return try allocator.dupe(u8, property_value);
    var parsed = try variant.parse.parsePropertyValue(allocator, property_value);
    const formatted = try parsed.formatForWrite(allocator);
    parsed.deinit(allocator);
    return formatted;
}

fn setPropertyHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const property_name = inv.getOption("property") orelse return error.Usage;
    const property_value = inv.getOption("value") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);

    const section_index: usize = blk: {
        if (inv.getOption("section-line")) |line_text| {
            const line = std.fmt.parseInt(usize, line_text, 10) catch return error.InvalidValue;
            break :blk text_format.document.findSectionIndexByLine(&doc, line) orelse return error.Usage;
        }
        if (inv.getOption("node-name")) |node_name| {
            break :blk text_format.document.findSectionIndexByNodeName(&doc, node_name) orelse return error.Usage;
        }
        if (inv.getOption("section")) |section_name| {
            break :blk text_format.document.findSectionIndexByTagName(&doc, section_name) orelse return error.Usage;
        }
        return error.Usage;
    };

    const written_value = try formatPropertyValueForWrite(cli.allocator, property_value, inv.flag("raw-value"));
    defer cli.allocator.free(written_value);

    try text_format.document.setSectionProperty(&doc, cli.allocator, section_index, property_name, written_value);

    const output_path = inv.getOption("output") orelse input_path;
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    const section = doc.sections.items[section_index];
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "updated {s} property {s} on section line {d}",
        .{ kind, property_name, section.line },
    );

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = output_path });
    try data.put(cli.allocator, "property", .{ .string = property_name });
    try data.put(cli.allocator, "value", .{ .string = property_value });
    try data.put(cli.allocator, "section_line", .{ .integer = @intCast(section.line) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn uidCacheListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    const cache_path = try uid_cache.defaultCachePath(cli.allocator, root);
    defer cli.allocator.free(cache_path);

    const cache = try uid_cache.loadFromFile(cli.allocator, cli.io, cache_path);

    var arr = std.json.Array.init(cli.allocator);
    for (cache.entries.items) |entry| {
        const uid_text = try resource_uid.idToText(cli.allocator, entry.id);
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "id", .{ .integer = entry.id });
        try row.put(cli.allocator, "uid", .{ .string = uid_text });
        try row.put(cli.allocator, "path", .{ .string = entry.path });
        try arr.append(.{ .object = row });
    }

    const msg = try std.fmt.allocPrint(cli.allocator, "{d} uid cache entries", .{cache.entries.items.len});
    return .{
        .data = .{ .array = arr },
        .messages = &.{msg},
    };
}

fn uidCacheLookupHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    const query = inv.positionals[0];

    const cache_path = try uid_cache.defaultCachePath(cli.allocator, root);
    defer cli.allocator.free(cache_path);

    const cache = try uid_cache.loadFromFile(cli.allocator, cli.io, cache_path);

    if (std.mem.startsWith(u8, query, "uid://")) {
        const id = resource_uid.textToId(query);
        if (id == resource_uid.invalid_id) return error.InvalidValue;
        const path = cache.pathForId(id) orelse return error.Usage;
        return .{
            .data = .{ .string = path },
            .messages = &.{path},
        };
    }

    if (cache.idForPath(query)) |id| {
        const uid_text = try resource_uid.idToText(cli.allocator, id);
        return .{
            .data = .{ .string = uid_text },
            .messages = &.{uid_text},
        };
    }

    return error.Usage;
}

fn inspectParseProperties(inv: *const spec.Invocation) bool {
    if (inv.flag("no-parse-properties")) return false;
    if (inv.flag("parse-properties")) return true;
    return inv.global.json_output;
}

fn inspectHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];
    const validate = !inv.flag("no-validate");
    const parse_properties = inspectParseProperties(inv);

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, path);

    var arr = std.json.Array.init(cli.allocator);
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
            try fields.put(cli.allocator, entry.key_ptr.*, value_json);
        }

        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "line", .{ .integer = @intCast(section.line) });
        try row.put(cli.allocator, "name", .{ .string = section.header.name });
        try row.put(cli.allocator, "fields", .{ .object = fields });
        try row.put(cli.allocator, "property_count", .{ .integer = @intCast(section.properties.items.len) });
        if (parse_properties) {
            const properties = try variant.property_line.buildPropertiesJson(cli.allocator, section.properties.items);
            try row.put(cli.allocator, "properties", .{ .array = properties });
        }
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "sections", .{ .array = arr });

    if (validate) {
        var setup = try ValidateSetup.init(cli, inv, path);
        defer setup.deinit(cli.allocator);
        const report = try id_validate.validateDocument(cli.allocator, &doc, setup.ctx);
        const issues = try buildIssuesJson(cli, &report);
        try data.put(cli.allocator, "issues", .{ .array = issues });
    }

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{s}: {d} sections",
        .{ kind, doc.sections.items.len },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn normalizeHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const output_path = inv.getOption("output") orelse input_path;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);

    var norm_stats: ?text_format.normalize_properties.Stats = null;
    if (inv.flag("normalize-properties")) {
        norm_stats = try text_format.normalize_properties.normalizeDocument(cli.allocator, &doc);
    }

    var prepare = try prepareSaveOptions(cli, inv, output_path);
    defer prepare.deinit(cli.allocator);
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    } else if (prepare.options) |options| {
        try text_format.save_prepare.prepareDocument(cli.allocator, &doc, options);
    }

    const summary = try std.fmt.allocPrint(cli.allocator, "prepared {s} save for {s}", .{ kind, output_path });
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = output_path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    try data.put(cli.allocator, "normalize_properties", .{ .bool = inv.flag("normalize-properties") });
    if (norm_stats) |stats| {
        try data.put(cli.allocator, "properties_normalized", .{ .integer = @intCast(stats.normalized) });
        try data.put(cli.allocator, "properties_preserved", .{ .integer = @intCast(stats.preserved) });
    }
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn sceneNormalizeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return normalizeHandler(ctx, inv, "scene");
}

fn resourceNormalizeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return normalizeHandler(ctx, inv, "resource");
}

fn sceneValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return validateHandler(ctx, inv, "scene");
}

fn sceneSetPropertyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return setPropertyHandler(ctx, inv, "scene");
}

fn resourceValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return validateHandler(ctx, inv, "resource");
}

fn resourceSetPropertyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return setPropertyHandler(ctx, inv, "resource");
}

fn sceneInspectHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return inspectHandler(ctx, inv, "scene");
}

fn sceneNodeListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];

    const doc = try text_format.document.parseFile(cli.allocator, cli.io, path);
    var list = try node_tree.collectNodes(cli.allocator, &doc);
    defer list.deinit(cli.allocator);

    const nodes = try node_tree.nodesToJsonArray(cli.allocator, list.nodes);

    var data: std.json.ObjectMap = .{};
    const path_copy = try cli.allocator.dupe(u8, path);
    try data.put(cli.allocator, "path", .{ .string = path_copy });
    try data.put(cli.allocator, "nodes", .{ .array = nodes });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{d} node(s) in {s}",
        .{ list.nodes.len, path },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn sceneNodeGetHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];

    const doc = try text_format.document.parseFile(cli.allocator, cli.io, path);
    var list = try node_tree.collectNodes(cli.allocator, &doc);
    defer list.deinit(cli.allocator);

    const node: *const node_tree.NodeInfo = blk: {
        if (inv.positionals.len >= 2) {
            const node_path = inv.positionals[1];
            break :blk node_tree.findByPath(&list, node_path) orelse return error.Usage;
        }
        const node_name = inv.getOption("node-name") orelse return error.Usage;
        const parent = inv.getOption("parent");
        break :blk (try node_tree.findByName(&list, node_name, parent)) orelse return error.Usage;
    };

    var data: std.json.ObjectMap = .{};
    const path_copy = try cli.allocator.dupe(u8, path);
    try data.put(cli.allocator, "path", .{ .string = path_copy });
    try data.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, node.name) });
    try data.put(cli.allocator, "type", .{ .string = try cli.allocator.dupe(u8, node.node_type) });
    if (node.parent.len > 0) {
        try data.put(cli.allocator, "parent", .{ .string = try cli.allocator.dupe(u8, node.parent) });
    }
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, node.path) });
    try data.put(cli.allocator, "section_line", .{ .integer = @intCast(node.section_line) });
    if (node.unique_id) |id| {
        try data.put(cli.allocator, "unique_id", .{ .integer = id });
    }

    const summary = try std.fmt.allocPrint(cli.allocator, "{s} ({s})", .{ node.name, node.path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

fn sceneNewHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const output_path = inv.getOption("output") orelse return error.Usage;
    const root_name = inv.getOption("root-name") orelse "Root";
    const root_type = inv.getOption("root-type") orelse "Node";

    var doc = try scene_edit.createNewScene(cli.allocator, root_name, root_type);
    defer doc.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "root_name", .{ .string = try cli.allocator.dupe(u8, root_name) });
    try data.put(cli.allocator, "root_type", .{ .string = try cli.allocator.dupe(u8, root_type) });
    try data.put(cli.allocator, "root_path", .{ .string = try std.fmt.allocPrint(cli.allocator, "/root/{s}", .{root_name}) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "created scene {s}", .{output_path});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneRefsHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];

    const doc = try text_format.document.parseFile(cli.allocator, cli.io, path);
    var list = try scene_refs.collectExtResources(cli.allocator, cli.io, &doc, projectRootFrom(inv));
    defer list.deinit(cli.allocator);

    const refs = try scene_refs.refsToJsonArray(cli.allocator, list.refs);
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, path) });
    try data.put(cli.allocator, "refs", .{ .array = refs });
    const summary = try std.fmt.allocPrint(cli.allocator, "{d} ext_resource(s) in {s}", .{ list.refs.len, path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneNodeAddHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const parent_path = inv.getOption("parent") orelse return error.Usage;
    const node_name = inv.getOption("name") orelse return error.Usage;
    const node_type = inv.getOption("type") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    var added = try scene_edit.addNode(cli.allocator, &doc, parent_path, node_name, node_type);
    defer added.deinit(cli.allocator);

    if (inv.getOption("property")) |property_name| {
        const property_value = inv.getOption("value") orelse return error.Usage;
        const written_value = try formatPropertyValueForWrite(cli.allocator, property_value, inv.flag("raw-value"));
        defer cli.allocator.free(written_value);
        try scene_edit.setNodeProperty(cli.allocator, &doc, added.path, property_name, written_value);
    }

    if (inv.flag("unique-name")) {
        try scene_edit.setNodeProperty(cli.allocator, &doc, added.path, "unique_name_in_owner", "true");
    }

    const output_path = inv.getOption("output") orelse input_path;
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    } else {
        var prepare = try prepareSaveOptions(cli, inv, output_path);
        defer prepare.deinit(cli.allocator);
        if (prepare.options) |options| {
            try text_format.save_prepare.prepareDocument(cli.allocator, &doc, options);
        }
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, added.path) });
    try data.put(cli.allocator, "parent", .{ .string = try cli.allocator.dupe(u8, parent_path) });
    try data.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, node_name) });
    try data.put(cli.allocator, "type", .{ .string = try cli.allocator.dupe(u8, node_type) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(added.section_index) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "added {s} at {s}", .{ node_name, added.path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneNodeRemoveHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const node_path = inv.positionals[1];

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const removed = try scene_edit.removeNode(cli.allocator, &doc, node_path, inv.flag("recursive"));

    const output_path = inv.getOption("output") orelse input_path;
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, node_path) });
    try data.put(cli.allocator, "removed_count", .{ .integer = @intCast(removed) });
    try data.put(cli.allocator, "recursive", .{ .bool = inv.flag("recursive") });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "removed {d} node section(s) from {s}", .{ removed, node_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneNodeRenameHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const node_path = inv.positionals[1];
    const new_name = inv.getOption("name") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const new_path = try scene_edit.renameNode(cli.allocator, &doc, node_path, new_name);
    defer cli.allocator.free(new_path);

    const output_path = inv.getOption("output") orelse input_path;
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "old_path", .{ .string = try cli.allocator.dupe(u8, node_path) });
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, new_path) });
    try data.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, new_name) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "renamed {s} to {s}", .{ node_path, new_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneNodeReparentHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const node_path = inv.positionals[1];
    const new_parent = inv.getOption("parent") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    try scene_edit.reparentNode(cli.allocator, &doc, node_path, new_parent);

    const output_path = inv.getOption("output") orelse input_path;
    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, node_path) });
    try data.put(cli.allocator, "parent", .{ .string = try cli.allocator.dupe(u8, new_parent) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "reparented {s} under {s}", .{ node_path, new_parent });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn referrersToJson(allocator: std.mem.Allocator, referrers: []const scene_resources.Referrer) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (referrers) |*ref| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "section_index", .{ .integer = @intCast(ref.section_index) });
        try row.put(allocator, "section_name", .{ .string = try allocator.dupe(u8, ref.section_name) });
        try row.put(allocator, "property", .{ .string = try allocator.dupe(u8, ref.property_raw) });
        try arr.append(.{ .object = row });
    }
    return arr;
}

fn sceneExtAddHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const res_type = inv.getOption("type") orelse return error.Usage;
    const res_path = inv.getOption("path") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const output_path = inv.getOption("output") orelse input_path;
    const seed_path = try saveSeedPath(cli, inv, output_path);
    defer cli.allocator.free(seed_path);

    var scene_uid: ?[]const u8 = null;
    defer if (scene_uid) |uid| cli.allocator.free(uid);
    if (projectRootFrom(inv)) |project_root| {
        scene_uid = try resource_uid_lookup.resolveExtResourceUid(cli.allocator, cli.io, project_root, res_path);
    }

    var added = try scene_resources.addExtResource(cli.allocator, &doc, seed_path, res_type, res_path);
    defer added.deinit(cli.allocator);
    if (scene_uid) |uid| {
        try doc.sections.items[added.section_index].header.setStringField(cli.allocator, "uid", uid);
    }

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, added.id) });
    try data.put(cli.allocator, "type", .{ .string = try cli.allocator.dupe(u8, res_type) });
    try data.put(cli.allocator, "resource_path", .{ .string = try cli.allocator.dupe(u8, res_path) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(added.section_index) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "added ext_resource {s} ({s})", .{ added.id, res_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneExtRemoveHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const resource_id = inv.positionals[1];

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const output_path = inv.getOption("output") orelse input_path;

    const removed_index = scene_resources.removeExtResource(cli.allocator, &doc, resource_id) catch |err| {
        if (err == error.ResourceInUse) {
            const referrers = try scene_resources.findReferrers(cli.allocator, &doc, resource_id, .ext);
            defer {
                for (referrers) |*ref| ref.deinit(cli.allocator);
                cli.allocator.free(referrers);
            }
            var data: std.json.ObjectMap = .{};
            try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, resource_id) });
            try data.put(cli.allocator, "referrers", .{ .array = try referrersToJson(cli.allocator, referrers) });
            const summary = try std.fmt.allocPrint(cli.allocator, "ext_resource {s} is still referenced", .{resource_id});
            try data.put(cli.allocator, "summary", .{ .string = summary });
            return .{
                .data = .{ .object = data },
                .messages = &.{summary},
                .exit_code = .failure,
            };
        }
        return err;
    };

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, resource_id) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(removed_index) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "removed ext_resource {s}", .{resource_id});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneSubAddHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const res_type = inv.getOption("type") orelse return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const output_path = inv.getOption("output") orelse input_path;
    const seed_path = try saveSeedPath(cli, inv, output_path);
    defer cli.allocator.free(seed_path);

    var properties: [1]scene_resources.PropertyInput = undefined;
    var property_count: usize = 0;

    // The normalized value has to outlive this block: addSubResource below
    // copies it into the document. Freeing it at the end of the `if` wrote
    // freed memory into the scene file.
    var normalized_value: ?[]u8 = null;
    defer if (normalized_value) |value| cli.allocator.free(value);

    if (inv.getOption("property")) |property_name| {
        const property_value = inv.getOption("value") orelse return error.Usage;

        var written_value: []const u8 = property_value;
        if (!inv.flag("raw-value")) {
            var parsed = try variant.parse.parsePropertyValue(cli.allocator, property_value);
            defer parsed.deinit(cli.allocator);
            normalized_value = try parsed.formatForWrite(cli.allocator);
            written_value = normalized_value.?;
        }

        properties[0] = .{ .name = property_name, .value = written_value };
        property_count = 1;
    }

    var added = try scene_resources.addSubResource(cli.allocator, &doc, seed_path, res_type, properties[0..property_count]);
    defer added.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, added.id) });
    try data.put(cli.allocator, "type", .{ .string = try cli.allocator.dupe(u8, res_type) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(added.section_index) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "added sub_resource {s}", .{added.id});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneSubRemoveHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const resource_id = inv.positionals[1];

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const output_path = inv.getOption("output") orelse input_path;

    const removed_index = scene_resources.removeSubResource(cli.allocator, &doc, resource_id) catch |err| {
        if (err == error.ResourceInUse) {
            const referrers = try scene_resources.findReferrers(cli.allocator, &doc, resource_id, .sub);
            defer {
                for (referrers) |*ref| ref.deinit(cli.allocator);
                cli.allocator.free(referrers);
            }
            var data: std.json.ObjectMap = .{};
            try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, resource_id) });
            try data.put(cli.allocator, "referrers", .{ .array = try referrersToJson(cli.allocator, referrers) });
            const summary = try std.fmt.allocPrint(cli.allocator, "sub_resource {s} is still referenced", .{resource_id});
            try data.put(cli.allocator, "summary", .{ .string = summary });
            return .{
                .data = .{ .object = data },
                .messages = &.{summary},
                .exit_code = .failure,
            };
        }
        return err;
    };

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, resource_id) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(removed_index) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "removed sub_resource {s}", .{resource_id});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn resourceInspectHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return inspectHandler(ctx, inv, "resource");
}

fn validateBatchHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);

    var results = std.json.Array.init(cli.allocator);
    var total_errors: usize = 0;

    for (inv.positionals) |path| {
        const doc = try text_format.document.parseFile(cli.allocator, cli.io, path);
        var setup = try ValidateSetup.init(cli, inv, path);
        const report = try id_validate.validateDocument(cli.allocator, &doc, setup.ctx);
        setup.deinit(cli.allocator);

        const issues = try buildIssuesJson(cli, &report);
        const errors = countErrors(&report);
        total_errors += errors;

        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "path", .{ .string = path });
        try row.put(cli.allocator, "issues", .{ .array = issues });
        try row.put(cli.allocator, "error_count", .{ .integer = @intCast(errors) });
        try results.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "files", .{ .array = results });
    try data.put(cli.allocator, "file_count", .{ .integer = @intCast(inv.positionals.len) });
    try data.put(cli.allocator, "error_count", .{ .integer = @intCast(total_errors) });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{s}: validated {d} file(s), {d} error(s)",
        .{ kind, inv.positionals.len, total_errors },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    if (total_errors > 0) {
        return .{ .data = .{ .object = data }, .messages = &.{}, .exit_code = .failure };
    }
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn retargetExtHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    const from_path = inv.getOption("from") orelse return error.Usage;
    const to_path = inv.getOption("to") orelse return error.Usage;
    if (inv.positionals.len == 0) return error.Usage;

    const cli = appFrom(ctx);
    var total_retargeted: usize = 0;
    var files_changed: usize = 0;

    var file_results = std.json.Array.init(cli.allocator);

    for (inv.positionals) |input_path| {
        var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
        const count = try text_format.batch.retargetExtResourcePaths(&doc, cli.allocator, from_path, to_path);
        if (count > 0) {
            files_changed += 1;
            total_retargeted += count;
            const output_path = inv.getOption("output") orelse input_path;
            if (!inv.flag("dry-run")) {
                try writeWithPrepare(cli, inv, output_path, &doc);
            }
        }

        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "path", .{ .string = input_path });
        try row.put(cli.allocator, "retargeted", .{ .integer = @intCast(count) });
        try file_results.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "from", .{ .string = from_path });
    try data.put(cli.allocator, "to", .{ .string = to_path });
    try data.put(cli.allocator, "files", .{ .array = file_results });
    try data.put(cli.allocator, "files_changed", .{ .integer = @intCast(files_changed) });
    try data.put(cli.allocator, "retargeted_count", .{ .integer = @intCast(total_retargeted) });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "retargeted {d} ext_resource path(s) in {d} file(s)",
        .{ total_retargeted, files_changed },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn roundTripHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const output_path = inv.getOption("output") orelse input_path;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    if (!inv.flag("dry-run")) {
        try text_format.writer.writeFile(cli.allocator, output_path, &doc, null);
    }

    const written = try text_format.writer.writeDocument(cli.allocator, &doc);
    defer cli.allocator.free(written);

    var reparsed = try text_format.document.parseBytes(cli.allocator, written);
    defer reparsed.deinit(cli.allocator);

    const equal = text_format.roundtrip.documentsEqual(&doc, &reparsed);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = input_path });
    try data.put(cli.allocator, "output", .{ .string = output_path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "structure_preserved", .{ .bool = equal });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });

    if (!equal) {
        return .{ .data = .{ .object = data }, .messages = &.{}, .exit_code = .failure };
    }
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneValidateBatchHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return validateBatchHandler(ctx, inv, "scene");
}

fn resourceValidateBatchHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return validateBatchHandler(ctx, inv, "resource");
}

fn sceneRetargetExtHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return retargetExtHandler(ctx, inv, "scene");
}

fn resourceRetargetExtHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return retargetExtHandler(ctx, inv, "resource");
}

fn sceneRoundTripHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return roundTripHandler(ctx, inv, "scene");
}

fn resourceRoundTripHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return roundTripHandler(ctx, inv, "resource");
}

fn compareGodotHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const reference_path = if (inv.getOption("reference")) |ref| ref else blk: {
        if (inv.positionals.len < 2) return error.Usage;
        break :blk inv.positionals[1];
    };

    var original = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    defer original.deinit(cli.allocator);
    var reference = try text_format.document.parseFile(cli.allocator, cli.io, reference_path);
    defer reference.deinit(cli.allocator);

    const match = text_format.roundtrip.documentsMatchGodotSave(cli.allocator, &original, &reference);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = input_path });
    try data.put(cli.allocator, "reference", .{ .string = reference_path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "matches_godot_save", .{ .bool = match });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{s}: {s} vs Godot reference {s}",
        .{ if (match) "matches" else "differs from", input_path, reference_path },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    if (!match) {
        return .{ .data = .{ .object = data }, .messages = &.{}, .exit_code = .failure };
    }
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneInstanceAddHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const parent_path = inv.getOption("parent") orelse return error.Usage;
    const node_name = inv.getOption("name") orelse return error.Usage;

    const scene_option = inv.getOption("scene");
    const catalog_id = inv.getOption("catalog-id");
    if ((scene_option == null and catalog_id == null) or (scene_option != null and catalog_id != null)) {
        return error.Usage;
    }

    var scene_res_path_owned: ?[]u8 = null;
    defer if (scene_res_path_owned) |path| cli.allocator.free(path);

    var scene_uid_owned: ?[]const u8 = null;
    defer if (scene_uid_owned) |uid| cli.allocator.free(uid);

    const scene_res_path: []const u8 = blk: {
        if (scene_option) |path| break :blk path;
        const id = catalog_id.?;
        if (catalog_builtins.isBuiltinId(id)) return error.BuiltinCatalogEntry;
        const project_root = projectRootFrom(inv) orelse return error.Usage;
        var scan = try catalog_scan.scanProject(cli.allocator, cli.io, project_root);
        defer scan.deinit(cli.allocator);
        const entry = catalog_scan.findValidEntryById(scan.entries, id) orelse return error.CatalogEntryNotFound;
        scene_res_path_owned = try cli.allocator.dupe(u8, entry.scene);
        if (entry.scene_uid.len > 0) {
            scene_uid_owned = try cli.allocator.dupe(u8, entry.scene_uid);
        }
        break :blk scene_res_path_owned.?;
    };

    if (scene_uid_owned == null) {
        if (projectRootFrom(inv)) |project_root| {
            scene_uid_owned = try scene_instance.readSceneUidFromResPath(cli.allocator, cli.io, project_root, scene_res_path);
        }
    }

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    const output_path = inv.getOption("output") orelse input_path;
    const seed_path = try saveSeedPath(cli, inv, output_path);
    defer cli.allocator.free(seed_path);

    var added = try scene_instance.addPackedSceneInstance(
        cli.allocator,
        &doc,
        seed_path,
        parent_path,
        node_name,
        scene_res_path,
        scene_uid_owned,
        inv.flag("editable"),
    );
    defer added.deinit(cli.allocator);

    if (inv.flag("unique-name")) {
        try scene_edit.setNodeProperty(cli.allocator, &doc, added.path, "unique_name_in_owner", "true");
    }

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    } else {
        var prepare = try prepareSaveOptions(cli, inv, output_path);
        defer prepare.deinit(cli.allocator);
        if (prepare.options) |options| {
            try text_format.save_prepare.prepareDocument(cli.allocator, &doc, options);
        }
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "node_path", .{ .string = try cli.allocator.dupe(u8, added.path) });
    try data.put(cli.allocator, "parent", .{ .string = try cli.allocator.dupe(u8, parent_path) });
    try data.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, node_name) });
    try data.put(cli.allocator, "scene", .{ .string = try cli.allocator.dupe(u8, scene_res_path) });
    try data.put(cli.allocator, "ext_resource_id", .{ .string = try cli.allocator.dupe(u8, added.ext_resource_id) });
    try data.put(cli.allocator, "section_index", .{ .integer = @intCast(added.section_index) });
    try data.put(cli.allocator, "editable", .{ .bool = added.editable });
    if (catalog_id) |id| {
        try data.put(cli.allocator, "catalog_id", .{ .string = try cli.allocator.dupe(u8, id) });
    }
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "instanced {s} at {s} from {s}", .{ node_name, added.path, scene_res_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn scenePlanHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const intent_path = inv.getOption("intent");
    const patch_path = inv.getOption("patch");
    if ((intent_path == null and patch_path == null) or (intent_path != null and patch_path != null)) {
        return error.Usage;
    }

    const input_bytes = blk: {
        const path = intent_path orelse patch_path.?;
        break :blk try std.Io.Dir.cwd().readFileAlloc(cli.io, path, cli.allocator, .unlimited);
    };
    defer cli.allocator.free(input_bytes);

    const scene_path = if (inv.positionals.len > 0) inv.positionals[0] else null;
    var doc_storage: ?text_format.document.Document = null;
    defer if (doc_storage) |*d| d.deinit(cli.allocator);

    const seed_path = if (scene_path) |path| blk: {
        const output_path = inv.getOption("output") orelse path;
        break :blk try saveSeedPath(cli, inv, output_path);
    } else try cli.allocator.dupe(u8, "res://scene.tscn");
    defer cli.allocator.free(seed_path);

    if (scene_path) |path| {
        doc_storage = try text_format.document.parseFile(cli.allocator, cli.io, path);
    }

    var planned = try scene_plan.planFromInput(cli.allocator, input_bytes, if (doc_storage) |*d| d else null, .{
        .seed_path = seed_path,
        .project_root = projectRootFrom(inv),
        .io = cli.io,
    });
    defer planned.deinit(cli.allocator);

    if (inv.getOption("write-patch")) |patch_out| {
        try io_util.writeFileAtomic(cli.io, patch_out, planned.patch_json);
    }

    var steps_json = std.json.Array.init(cli.allocator);
    for (planned.steps) |*step| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "index", .{ .integer = @intCast(step.index) });
        try row.put(cli.allocator, "recipe", .{ .string = try cli.allocator.dupe(u8, step.recipe) });
        try row.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, step.summary) });
        try row.put(cli.allocator, "op_count", .{ .integer = @intCast(step.op_count) });
        try steps_json.append(.{ .object = row });
    }

    var preview_json: ?std.json.Array = null;
    if (planned.preview) |preview| {
        var arr = std.json.Array.init(cli.allocator);
        for (preview.results) |*item| {
            var row: std.json.ObjectMap = .{};
            try row.put(cli.allocator, "index", .{ .integer = @intCast(item.index) });
            try row.put(cli.allocator, "op", .{ .string = try cli.allocator.dupe(u8, item.op) });
            try row.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, item.summary) });
            try arr.append(.{ .object = row });
        }
        preview_json = arr;
    }

    var op_count: usize = 0;
    for (planned.steps) |step| op_count += step.op_count;

    var data: std.json.ObjectMap = .{};
    if (scene_path) |path| {
        try data.put(cli.allocator, "scene", .{ .string = try cli.allocator.dupe(u8, path) });
    }
    if (intent_path) |path| {
        try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, path) });
    }
    if (patch_path) |path| {
        try data.put(cli.allocator, "patch_input", .{ .string = try cli.allocator.dupe(u8, path) });
    }
    try data.put(cli.allocator, "patch", .{ .string = try cli.allocator.dupe(u8, planned.patch_json) });
    try data.put(cli.allocator, "steps", .{ .array = steps_json });
    if (preview_json) |arr| {
        try data.put(cli.allocator, "preview", .{ .array = arr });
        try data.put(cli.allocator, "preview_op_count", .{ .integer = @intCast(planned.preview.?.applied_count) });
    }
    try data.put(cli.allocator, "op_count", .{ .integer = @intCast(op_count) });
    const summary = try std.fmt.allocPrint(cli.allocator, "planned {d} patch op(s)", .{op_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const patch_path_opt = inv.getOption("patch");
    const intent_path_opt = inv.getOption("intent");
    if ((patch_path_opt == null and intent_path_opt == null) or (patch_path_opt != null and intent_path_opt != null)) {
        return error.Usage;
    }

    var snapshot_path_owned: ?[]const u8 = null;
    defer if (snapshot_path_owned) |path| cli.allocator.free(path);

    const snapshot_path: ?[]const u8 = blk: {
        if (inv.getOption("snapshot")) |path| break :blk path;
        if (inv.flag("auto-snapshot")) {
            snapshot_path_owned = try scene_undo.defaultSnapshotPath(cli.allocator, input_path);
            break :blk snapshot_path_owned.?;
        }
        break :blk null;
    };

    if (snapshot_path) |path| {
        if (!inv.flag("dry-run")) {
            try scene_undo.writeSnapshot(cli.io, input_path, path);
        }
    }

    var undo_recorder_storage: ?scene_undo.UndoRecorder = null;
    const record_undo = inv.flag("record-undo") or inv.getOption("write-undo-patch") != null;
    if (record_undo) {
        undo_recorder_storage = scene_undo.UndoRecorder.init(cli.allocator);
    }
    defer if (undo_recorder_storage) |*recorder| recorder.deinit();

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    var doc_before = try text_format.document.cloneDocument(cli.allocator, &doc);
    defer doc_before.deinit(cli.allocator);
    const output_path = inv.getOption("output") orelse input_path;
    const seed_path = try saveSeedPath(cli, inv, output_path);
    defer cli.allocator.free(seed_path);

    var patch_file_bytes: ?[]const u8 = null;
    defer if (patch_file_bytes) |bytes| cli.allocator.free(bytes);
    var planned_patch_bytes: ?[]const u8 = null;
    defer if (planned_patch_bytes) |bytes| cli.allocator.free(bytes);

    const patch_bytes: []const u8 = blk: {
        if (patch_path_opt) |patch_path| {
            patch_file_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, patch_path, cli.allocator, .unlimited) catch return error.Io;
            break :blk patch_file_bytes.?;
        }
        const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path_opt.?, cli.allocator, .unlimited) catch return error.Io;
        defer cli.allocator.free(intent_bytes);

        var planned = try scene_plan.planFromInput(cli.allocator, intent_bytes, null, .{
            .seed_path = seed_path,
            .project_root = projectRootFrom(inv),
            .io = cli.io,
        });
        defer planned.deinit(cli.allocator);

        planned_patch_bytes = try cli.allocator.dupe(u8, planned.patch_json);
        break :blk planned_patch_bytes.?;
    };

    const strict = !inv.flag("no-strict");
    var applied = try scene_patch.applyPatchJson(cli.allocator, &doc, patch_bytes, .{
        .seed_path = seed_path,
        .project_root = projectRootFrom(inv),
        .io = cli.io,
        .strict = strict,
        .undo = if (undo_recorder_storage) |*recorder| recorder else null,
    });
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try writeWithPrepare(cli, inv, output_path, &doc);
    } else {
        var prepare = try prepareSaveOptions(cli, inv, output_path);
        defer prepare.deinit(cli.allocator);
        if (prepare.options) |options| {
            try text_format.save_prepare.prepareDocument(cli.allocator, &doc, options);
            try text_format.save_prepare.prepareDocument(cli.allocator, &doc_before, options);
        }
    }

    var preview_diff: ?std.json.ObjectMap = null;
    if (inv.flag("dry-run")) {
        var diff = try scene_diff.diffDocuments(cli.allocator, &doc_before, &doc, .{
            .include_properties = inv.flag("preview-properties"),
        });
        defer diff.deinit(cli.allocator);
        preview_diff = try scene_diff.diffToObjectMap(cli.allocator, &diff);
    }

    var op_results = std.json.Array.init(cli.allocator);
    for (applied.results) |*item| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "index", .{ .integer = @intCast(item.index) });
        try row.put(cli.allocator, "op", .{ .string = try cli.allocator.dupe(u8, item.op) });
        try row.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, item.summary) });
        try op_results.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
    if (patch_path_opt) |patch_path| {
        try data.put(cli.allocator, "patch", .{ .string = try cli.allocator.dupe(u8, patch_path) });
    }
    if (intent_path_opt) |intent_path| {
        try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    }
    if (snapshot_path) |path| {
        try data.put(cli.allocator, "snapshot", .{ .string = try cli.allocator.dupe(u8, path) });
    }
    if (undo_recorder_storage) |*recorder| {
        const undo_json = try recorder.toPatchJson(cli.allocator);
        defer cli.allocator.free(undo_json);
        if (inv.getOption("write-undo-patch")) |undo_path| {
            try io_util.writeFileAtomic(cli.io, undo_path, undo_json);
            try data.put(cli.allocator, "undo_patch_path", .{ .string = try cli.allocator.dupe(u8, undo_path) });
        }
        try data.put(cli.allocator, "undo_patch", .{ .string = try cli.allocator.dupe(u8, undo_json) });
    }
    try data.put(cli.allocator, "applied_count", .{ .integer = @intCast(applied.applied_count) });
    try data.put(cli.allocator, "results", .{ .array = op_results });
    try data.put(cli.allocator, "strict", .{ .bool = strict });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    if (preview_diff) |diff_map| {
        try data.put(cli.allocator, "preview_diff", .{ .object = diff_map });
    }
    const summary = try std.fmt.allocPrint(cli.allocator, "applied {d} patch op(s) to {s}", .{ applied.applied_count, output_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneDiffHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len < 2) return error.Usage;
    const cli = appFrom(ctx);
    const path_a = inv.positionals[0];
    const path_b = inv.positionals[1];
    const include_properties = inv.flag("properties");

    var doc_a = try text_format.document.parseFile(cli.allocator, cli.io, path_a);
    defer doc_a.deinit(cli.allocator);
    var doc_b = try text_format.document.parseFile(cli.allocator, cli.io, path_b);
    defer doc_b.deinit(cli.allocator);

    var diff = try scene_diff.diffDocuments(cli.allocator, &doc_a, &doc_b, .{
        .include_properties = include_properties,
    });
    defer diff.deinit(cli.allocator);

    var data = try scene_diff.diffToObjectMap(cli.allocator, &diff);
    try data.put(cli.allocator, "scene_a", .{ .string = try cli.allocator.dupe(u8, path_a) });
    try data.put(cli.allocator, "scene_b", .{ .string = try cli.allocator.dupe(u8, path_b) });

    const total_diffs = diff.nodes.len + diff.properties.len;
    const summary = if (diff.identical)
        try std.fmt.allocPrint(cli.allocator, "{s} and {s} are identical", .{ path_a, path_b })
    else
        try std.fmt.allocPrint(cli.allocator, "{d} difference(s) between {s} and {s}", .{ total_diffs, path_a, path_b });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn templatesRootFrom(cli: *const app_mod.App, inv: *const spec.Invocation) []const u8 {
    return scene_templates.resolveTemplatesRoot(
        cli.allocator,
        cli.environ,
        inv.getOption("templates-root"),
    );
}

fn sceneTemplateListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var items = std.json.Array.init(cli.allocator);
    for (scene_templates.listTemplates()) |template| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, template.id) });
        try row.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, template.relative_path) });
        try row.put(cli.allocator, "description", .{ .string = try cli.allocator.dupe(u8, template.description) });
        try items.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "templates_root", .{ .string = try cli.allocator.dupe(u8, templatesRootFrom(cli, inv)) });
    try data.put(cli.allocator, "count", .{ .integer = @intCast(items.items.len) });
    try data.put(cli.allocator, "templates", .{ .array = items });
    try data.put(cli.allocator, "summary", .{ .string = try std.fmt.allocPrint(cli.allocator, "{d} built-in template(s)", .{items.items.len}) });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneTemplateShowHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const template_id = inv.positionals[0];
    const info = scene_templates.findTemplate(template_id) orelse return error.Usage;

    const bytes = try scene_templates.readTemplateBytes(cli.allocator, cli.io, templatesRootFrom(cli, inv), template_id);
    defer cli.allocator.free(bytes);

    var doc = try text_format.document.parseBytes(cli.allocator, bytes);
    defer doc.deinit(cli.allocator);

    const parse_properties = !inv.flag("no-parse-properties");
    const show = try scene_templates.buildShowData(cli.allocator, &doc, parse_properties);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "id", .{ .string = try cli.allocator.dupe(u8, info.id) });
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, info.relative_path) });
    try data.put(cli.allocator, "description", .{ .string = try cli.allocator.dupe(u8, info.description) });
    try data.put(cli.allocator, "section_count", .{ .integer = @intCast(show.section_count) });
    try data.put(cli.allocator, "node_count", .{ .integer = @intCast(show.node_count) });
    try data.put(cli.allocator, "nodes", .{ .array = show.nodes });
    try data.put(cli.allocator, "sections", .{ .array = show.sections });
    if (inv.flag("content")) {
        try data.put(cli.allocator, "content", .{ .string = try cli.allocator.dupe(u8, bytes) });
    }
    try data.put(cli.allocator, "summary", .{ .string = try std.fmt.allocPrint(cli.allocator, "template {s}: {d} node(s), {d} section(s)", .{ template_id, show.node_count, show.section_count }) });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneTemplateCopyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const template_id = inv.positionals[0];
    const output_path = inv.getOption("output") orelse return error.Usage;
    _ = scene_templates.findTemplate(template_id) orelse return error.Usage;

    var renames: []scene_templates.RenamePair = &.{};
    defer if (renames.len > 0) scene_templates.freeRenameList(cli.allocator, renames);
    if (inv.getOption("rename-node")) |rename_text| {
        renames = try scene_templates.parseRenameList(cli.allocator, rename_text);
    }

    var property_sets: []scene_templates.PropertySet = &.{};
    defer if (property_sets.len > 0) scene_templates.freePropertyList(cli.allocator, property_sets);
    if (inv.getOption("set-property")) |property_text| {
        property_sets = try scene_templates.parsePropertyList(cli.allocator, property_text);
    }

    if (!inv.flag("dry-run")) {
        var prepare = try prepareSaveOptions(cli, inv, output_path);
        defer prepare.deinit(cli.allocator);
        try scene_templates.copyTemplateToFile(
            cli.allocator,
            cli.io,
            templatesRootFrom(cli, inv),
            template_id,
            output_path,
            prepare.options,
            .{
                .renames = renames,
                .property_sets = property_sets,
            },
        );
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "template", .{ .string = try cli.allocator.dupe(u8, template_id) });
    try data.put(cli.allocator, "output", .{ .string = try cli.allocator.dupe(u8, output_path) });
    try data.put(cli.allocator, "rename_count", .{ .integer = @intCast(renames.len) });
    try data.put(cli.allocator, "property_set_count", .{ .integer = @intCast(property_sets.len) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    try data.put(cli.allocator, "summary", .{ .string = try std.fmt.allocPrint(cli.allocator, "copied template {s} to {s}", .{ template_id, output_path }) });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneRestoreHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const target_path = inv.positionals[0];
    const snapshot_path = inv.getOption("from") orelse inv.getOption("snapshot") orelse return error.Usage;

    if (!inv.flag("dry-run")) {
        try scene_undo.writeSnapshot(cli.io, snapshot_path, target_path);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, target_path) });
    try data.put(cli.allocator, "snapshot", .{ .string = try cli.allocator.dupe(u8, snapshot_path) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "restored {s} from {s}", .{ target_path, snapshot_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn sceneCompareGodotHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return compareGodotHandler(ctx, inv, "scene");
}

fn resourceCompareGodotHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return compareGodotHandler(ctx, inv, "resource");
}

pub fn uidCacheCommands() spec.CommandSpec {
    const project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root (directory containing project.godot)",
    };

    return .{
        .name = "cache",
        .summary = "Inspect project uid_cache.bin",
        .children = &.{
            .{
                .name = "list",
                .summary = "List all UID cache entries",
                .options = &.{project_root_opt},
                .handler = uidCacheListHandler,
            },
            .{
                .name = "lookup",
                .summary = "Resolve uid:// text to path or path to uid:// text",
                .options = &.{project_root_opt},
                .handler = uidCacheLookupHandler,
            },
        },
    };
}

pub fn sceneCommands() spec.CommandSpec {
    const project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root for uid_cache lookup and res:// seed path",
    };
    const id_session_options = [_]spec.OptionSpec{
        .{ .long = "id-session", .kind = .path, .description = "Path to ext_resource id session cache JSON" },
        .{ .long = "no-id-session", .kind = .flag, .description = "Do not load or update ext_resource id session cache" },
        .{ .long = "godot-save-format", .kind = .flag, .description = "Strip Godot-omitted header fields and default sub_resource properties" },
        .{ .long = "normalize-properties", .kind = .flag, .description = "Rewrite property values through Variant parse/format" },
    };
    const save_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root for res:// seed path and id session cache" },
        .{ .long = "resource-path", .kind = .string, .description = "Godot res:// path for ID seeding (overrides --project-root)" },
        .{ .long = "no-prepare-save", .kind = .flag, .description = "Skip Godot save preparation (ID repair/sort)" },
        .{ .long = "output", .kind = .path, .description = "Output path (default: overwrite input)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Parse and validate edit without writing" },
    } ++ id_session_options;
    const set_property_options = [_]spec.OptionSpec{
        .{ .long = "property", .kind = .string, .description = "Property name to set" },
        .{ .long = "value", .kind = .string, .description = "Property value (normalized unless --raw-value)" },
        .{ .long = "raw-value", .kind = .flag, .description = "Write value verbatim without Variant normalization" },
        .{ .long = "node-name", .kind = .string, .description = "Target node section by name attribute" },
        .{ .long = "section-line", .kind = .string, .description = "Target section by header line number" },
        .{ .long = "section", .kind = .string, .description = "Target section by tag name (e.g. resource)" },
    } ++ save_options;
    const batch_options = [_]spec.OptionSpec{
        project_root_opt,
    };
    const retarget_options = [_]spec.OptionSpec{
        .{ .long = "from", .kind = .string, .description = "Current ext_resource path (res://…)" },
        .{ .long = "to", .kind = .string, .description = "New ext_resource path (res://…)" },
        .{ .long = "project-root", .kind = .path, .description = "Godot project root for res:// seed path" },
        .{ .long = "resource-path", .kind = .string, .description = "Godot res:// path for ID seeding" },
        .{ .long = "no-prepare-save", .kind = .flag, .description = "Skip Godot save preparation on write" },
        .{ .long = "output", .kind = .path, .description = "Output path when processing a single file" },
        .{ .long = "dry-run", .kind = .flag, .description = "Report changes without writing" },
    } ++ id_session_options;
    const roundtrip_options = [_]spec.OptionSpec{
        .{ .long = "output", .kind = .path, .description = "Output path (default: overwrite input)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Check structure preservation without writing" },
    };
    const compare_godot_options = [_]spec.OptionSpec{
        .{ .long = "reference", .kind = .path, .description = "Godot-saved reference file (default: second positional)" },
    };
    const optional_project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root (optional; ignored for file-only reads)",
    };
    const inspect_options = [_]spec.OptionSpec{
        project_root_opt,
        .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" },
        .{ .long = "parse-properties", .kind = .flag, .description = "Include parsed property values in JSON output" },
        .{ .long = "no-parse-properties", .kind = .flag, .description = "Omit parsed properties (faster for large files)" },
    };
    const node_list_options = [_]spec.OptionSpec{
        optional_project_root_opt,
    };
    const node_get_options = [_]spec.OptionSpec{
        .{ .long = "node-name", .kind = .string, .description = "Node name to look up (alternative to node path positional)" },
        .{ .long = "parent", .kind = .string, .description = "Parent attribute filter when using --node-name (e.g. \".\" or \"Root\")" },
        optional_project_root_opt,
    };
    const node_edit_options = [_]spec.OptionSpec{
        .{ .long = "parent", .kind = .string, .description = "Viewport parent path (e.g. /root/Main)" },
        .{ .long = "name", .kind = .string, .description = "Node name" },
        .{ .long = "type", .kind = .string, .description = "Godot node class name (e.g. CharacterBody2D)" },
        .{ .long = "property", .kind = .string, .description = "Optional property to set on the new node" },
        .{ .long = "value", .kind = .string, .description = "Property value (Variant text)" },
        .{ .long = "raw-value", .kind = .flag, .description = "Write property value verbatim" },
        .{ .long = "unique-name", .kind = .flag, .description = "Set unique_name_in_owner on the new node (Access as Unique Name / %Name)" },
        .{ .long = "recursive", .kind = .flag, .description = "Remove descendant nodes as well" },
    } ++ save_options;
    const plan_options = [_]spec.OptionSpec{
        .{ .long = "intent", .kind = .path, .description = "Intent JSON with steps/recipes (expands to patch ops)" },
        .{ .long = "patch", .kind = .path, .description = "Existing patch JSON to validate and preview" },
        .{ .long = "write-patch", .kind = .path, .description = "Write expanded patch JSON to this path" },
        project_root_opt,
    };
    const apply_options = [_]spec.OptionSpec{
        .{ .long = "patch", .kind = .path, .description = "JSON patch file with { \"ops\": [ … ] }" },
        .{ .long = "intent", .kind = .path, .description = "Intent JSON (expands to patch ops via scene plan)" },
        .{ .long = "snapshot", .kind = .path, .description = "Copy scene to this path before applying" },
        .{ .long = "auto-snapshot", .kind = .flag, .description = "Save snapshot to <scene>.godot-cli-snapshot before apply" },
        .{ .long = "record-undo", .kind = .flag, .description = "Record undo patch ops in JSON output" },
        .{ .long = "write-undo-patch", .kind = .path, .description = "Write undo patch JSON to this path (implies --record-undo)" },
        .{ .long = "no-strict", .kind = .flag, .description = "Continue applying ops after a failure (default: stop on first error)" },
        .{ .long = "preview-properties", .kind = .flag, .description = "With --dry-run, include property-level changes in preview_diff" },
    } ++ save_options;
    const template_options = [_]spec.OptionSpec{
        .{ .long = "templates-root", .kind = .path, .description = "Directory containing built-in templates (default: compile-time templates/)" },
        .{ .long = "content", .kind = .flag, .description = "Include raw .tscn source in template show output" },
        .{ .long = "no-parse-properties", .kind = .flag, .description = "Omit parsed properties from template show sections" },
    };
    const template_copy_options = [_]spec.OptionSpec{
        .{ .long = "templates-root", .kind = .path, .description = "Directory containing built-in templates (default: compile-time templates/)" },
        .{ .long = "rename-node", .kind = .string, .description = "Rename node(s) after copy: Old:New pairs, comma-separated" },
        .{ .long = "set-property", .kind = .string, .description = "Set properties after copy: path/prop=value or path|prop|value, comma-separated" },
        .{ .long = "project-root", .kind = .path, .description = "Godot project root for res:// seed path and id session cache" },
        .{ .long = "resource-path", .kind = .string, .description = "Godot res:// path for ID seeding (overrides --project-root)" },
        .{ .long = "no-prepare-save", .kind = .flag, .description = "Skip Godot save preparation (ID repair/sort)" },
        .{ .long = "output", .kind = .path, .description = "Output path (required)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Report copy without writing" },
        .{ .long = "id-session", .kind = .path, .description = "Path to ext_resource id session cache JSON" },
        .{ .long = "no-id-session", .kind = .flag, .description = "Do not load or update ext_resource id session cache" },
        .{ .long = "godot-save-format", .kind = .flag, .description = "Strip Godot-omitted header fields and default sub_resource properties" },
        .{ .long = "normalize-properties", .kind = .flag, .description = "Rewrite property values through Variant parse/format" },
    };
    const diff_options = [_]spec.OptionSpec{
        .{ .long = "properties", .kind = .flag, .description = "Include node property diffs (added/removed/changed)" },
        optional_project_root_opt,
    };
    const restore_options = [_]spec.OptionSpec{
        .{ .long = "from", .kind = .path, .description = "Snapshot file to restore from" },
        .{ .long = "snapshot", .kind = .path, .description = "Alias for --from" },
        .{ .long = "dry-run", .kind = .flag, .description = "Report restore without writing" },
    };
    const instance_add_options = [_]spec.OptionSpec{
        .{ .long = "parent", .kind = .string, .description = "Viewport parent path (e.g. /root/Main)" },
        .{ .long = "name", .kind = .string, .description = "Node name for the new instance" },
        .{ .long = "scene", .kind = .string, .description = "PackedScene res:// path to instance" },
        .{ .long = "catalog-id", .kind = .string, .description = "Project catalog id (resolves scene path; requires --project-root)" },
        .{ .long = "editable", .kind = .flag, .description = "Mark the instance editable in the parent scene ([editable path=...])" },
        .{ .long = "unique-name", .kind = .flag, .description = "Set unique_name_in_owner on the instance root (%Name from owner scripts)" },
    } ++ save_options;
    // save_options carries an --output that defaults to overwriting the input,
    // which scene new redefines as required. Dropping it here keeps the option
    // declared once: twice over, help listed it twice and completions offered
    // it twice.
    const scene_new_options = [_]spec.OptionSpec{
        .{ .long = "output", .kind = .path, .description = "Output .tscn path (required)" },
        .{ .long = "root-name", .kind = .string, .description = "Scene root node name (default: Root)" },
        .{ .long = "root-type", .kind = .string, .description = "Scene root node type (default: Node)" },
    } ++ withoutOption(&save_options, "output");
    const refs_options = [_]spec.OptionSpec{
        project_root_opt,
    };
    const ext_add_options = [_]spec.OptionSpec{
        .{ .long = "type", .kind = .string, .description = "Godot resource type (e.g. Script, PackedScene)" },
        .{ .long = "path", .kind = .string, .description = "Godot res:// path for the external resource" },
    } ++ save_options;
    const sub_add_options = [_]spec.OptionSpec{
        .{ .long = "type", .kind = .string, .description = "Godot resource class (e.g. RectangleShape2D)" },
        .{ .long = "property", .kind = .string, .description = "Optional sub_resource property to set" },
        .{ .long = "value", .kind = .string, .description = "Property value (Variant text)" },
        .{ .long = "raw-value", .kind = .flag, .description = "Write property value verbatim" },
    } ++ save_options;
    const resource_remove_options = save_options;

    return .{
        .name = "scene",
        .summary = "Inspect and edit Godot scene files",
        .children = &.{
            .{
                .name = "new",
                .summary = "Create a new empty scene file",
                .description = "Writes a minimal gd_scene with a single root node. Use scene node add to build the tree.",
                .options = scene_new_options,
                .handler = sceneNewHandler,
            },
            .{
                .name = "refs",
                .summary = "List ext_resource references in a scene",
                .description = "With --project-root, resolves res:// paths to filesystem paths and reports whether each file exists.",
                .options = &refs_options,
                .handler = sceneRefsHandler,
            },
            .{
                .name = "ext",
                .summary = "Add or remove external resources",
                .children = &.{
                    .{
                        .name = "add",
                        .summary = "Add an ext_resource section",
                        .description = "Inserts before node sections and assigns a Godot-style id (e.g. 1_ab12c).",
                        .options = &ext_add_options,
                        .handler = sceneExtAddHandler,
                    },
                    .{
                        .name = "remove",
                        .summary = "Remove an ext_resource by id",
                        .description = "Fails with referrer list if the id is still referenced in property text.",
                        .options = &resource_remove_options,
                        .handler = sceneExtRemoveHandler,
                    },
                },
            },
            .{
                .name = "sub",
                .summary = "Add or remove sub-resources",
                .children = &.{
                    .{
                        .name = "add",
                        .summary = "Add a sub_resource section",
                        .description = "Inserts before node sections and assigns a Godot-style id (e.g. CapsuleShape3D_ab12c).",
                        .options = &sub_add_options,
                        .handler = sceneSubAddHandler,
                    },
                    .{
                        .name = "remove",
                        .summary = "Remove a sub_resource by id",
                        .description = "Fails with referrer list if the id is still referenced in property text.",
                        .options = &resource_remove_options,
                        .handler = sceneSubRemoveHandler,
                    },
                },
            },
            .{
                .name = "inspect",
                .summary = "Parse a .tscn file and report structure and ID issues",
                .description = "Reads section headers, parsed properties (with --json), and runs ID validation. Pass --project-root to check uids against uid_cache.bin.",
                .options = &inspect_options,
                .handler = sceneInspectHandler,
            },
            .{
                .name = "node",
                .summary = "List and query scene node tree",
                .children = &.{
                    .{
                        .name = "list",
                        .summary = "List all nodes in a scene with paths and section lines",
                        .options = &node_list_options,
                        .handler = sceneNodeListHandler,
                    },
                    .{
                        .name = "get",
                        .summary = "Get one node by viewport path or by name",
                        .description = "Pass file and node path (e.g. /root/Root/Player), or use --node-name with optional --parent.",
                        .options = &node_get_options,
                        .handler = sceneNodeGetHandler,
                    },
                    .{
                        .name = "add",
                        .summary = "Add a child node under a parent path",
                        .description = "Requires --parent, --name, and --type. Assigns unique_id on save via save preparation.",
                        .options = &node_edit_options,
                        .handler = sceneNodeAddHandler,
                    },
                    .{
                        .name = "remove",
                        .summary = "Remove a node by viewport path",
                        .description = "Fails if the node has children unless --recursive is set.",
                        .options = &node_edit_options,
                        .handler = sceneNodeRemoveHandler,
                    },
                    .{
                        .name = "rename",
                        .summary = "Rename a node and rewrite descendant parent attributes",
                        .options = &node_edit_options,
                        .handler = sceneNodeRenameHandler,
                    },
                    .{
                        .name = "reparent",
                        .summary = "Move a node under a new parent path",
                        .options = &node_edit_options,
                        .handler = sceneNodeReparentHandler,
                    },
                },
            },
            .{
                .name = "instance",
                .summary = "Add instanced PackedScene nodes",
                .children = &.{
                    .{
                        .name = "add",
                        .summary = "Instance a PackedScene under a parent node",
                        .description = "Adds ext_resource type=PackedScene and a node with instance=ExtResource(...). Use --scene or --catalog-id (project entries only).",
                        .options = &instance_add_options,
                        .handler = sceneInstanceAddHandler,
                    },
                },
            },
            .{
                .name = "template",
                .summary = "Built-in scene templates for scaffolding",
                .children = &.{
                    .{
                        .name = "list",
                        .summary = "List built-in scene templates",
                        .options = &template_options,
                        .handler = sceneTemplateListHandler,
                    },
                    .{
                        .name = "show",
                        .summary = "Show template metadata, node tree, and sections",
                        .description = "Like scene inspect + node list for a built-in template. Use --content for raw .tscn text.",
                        .options = &template_options,
                        .handler = sceneTemplateShowHandler,
                    },
                    .{
                        .name = "copy",
                        .summary = "Copy a template to a new scene file",
                        .description = "Requires --output. Optional --rename-node and --set-property apply edits before save preparation.",
                        .options = &template_copy_options,
                        .handler = sceneTemplateCopyHandler,
                    },
                },
            },
            .{
                .name = "plan",
                .summary = "Expand intent JSON to a patch and preview (no write)",
                .description = "Accepts --intent or --patch. Optional scene path positional dry-runs the patch. See docs/agent_scene_authoring.md.",
                .options = &plan_options,
                .handler = scenePlanHandler,
            },
            .{
                .name = "apply",
                .summary = "Apply a declarative JSON patch to a scene",
                .description = "Batch node/resource/instance edits. Use --patch or --intent. See docs/agent_scene_authoring.md.",
                .options = &apply_options,
                .handler = sceneApplyHandler,
            },
            .{
                .name = "diff",
                .summary = "Compare node trees between two scenes",
                .description = "Reports added, removed, and type-changed nodes. Use --properties for property-level diff.",
                .options = &diff_options,
                .handler = sceneDiffHandler,
            },
            .{
                .name = "restore",
                .summary = "Restore a scene from a snapshot file",
                .description = "Copies --from snapshot over the target scene (full file restore).",
                .options = &restore_options,
                .handler = sceneRestoreHandler,
            },
            .{
                .name = "validate",
                .summary = "Validate scene IDs and references (fails on errors)",
                .options = &.{project_root_opt},
                .handler = sceneValidateHandler,
            },
            .{
                .name = "validate-batch",
                .summary = "Validate multiple scene files (aggregated JSON, exit 1 on any error)",
                .options = &batch_options,
                .handler = sceneValidateBatchHandler,
            },
            .{
                .name = "set-property",
                .summary = "Set a property on a node section and save the scene",
                .description = "Target a section with --node-name or --section-line. Value is written verbatim after =.",
                .options = &set_property_options,
                .handler = sceneSetPropertyHandler,
            },
            .{
                .name = "normalize",
                .summary = "Repair scene-local IDs and sort ext_resource sections for save",
                .description = "Runs Godot-compatible save preparation without editing properties.",
                .options = &save_options,
                .handler = sceneNormalizeHandler,
            },
            .{
                .name = "retarget-ext",
                .summary = "Replace ext_resource paths across one or more files",
                .options = &retarget_options,
                .handler = sceneRetargetExtHandler,
            },
            .{
                .name = "round-trip",
                .summary = "Parse and rewrite a scene; fail if structure is not preserved",
                .options = &roundtrip_options,
                .handler = sceneRoundTripHandler,
            },
            .{
                .name = "compare-godot",
                .summary = "Compare a scene to a Godot headless save (semantic match)",
                .description = "Ignores ext_resource id suffixes and default sub_resource fields stripped by Godot.",
                .options = &compare_godot_options,
                .handler = sceneCompareGodotHandler,
            },
        },
    };
}

pub fn resourceCommands() spec.CommandSpec {
    const project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root for uid_cache lookup and res:// seed path",
    };
    const id_session_options = [_]spec.OptionSpec{
        .{ .long = "id-session", .kind = .path, .description = "Path to ext_resource id session cache JSON" },
        .{ .long = "no-id-session", .kind = .flag, .description = "Do not load or update ext_resource id session cache" },
        .{ .long = "godot-save-format", .kind = .flag, .description = "Strip Godot-omitted header fields and default sub_resource properties" },
        .{ .long = "normalize-properties", .kind = .flag, .description = "Rewrite property values through Variant parse/format" },
    };
    const save_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root for res:// seed path and id session cache" },
        .{ .long = "resource-path", .kind = .string, .description = "Godot res:// path for ID seeding (overrides --project-root)" },
        .{ .long = "no-prepare-save", .kind = .flag, .description = "Skip Godot save preparation (ID repair/sort)" },
        .{ .long = "output", .kind = .path, .description = "Output path (default: overwrite input)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Parse and validate edit without writing" },
    } ++ id_session_options;
    const set_property_options = [_]spec.OptionSpec{
        .{ .long = "property", .kind = .string, .description = "Property name to set" },
        .{ .long = "value", .kind = .string, .description = "Property value (normalized unless --raw-value)" },
        .{ .long = "raw-value", .kind = .flag, .description = "Write value verbatim without Variant normalization" },
        .{ .long = "section-line", .kind = .string, .description = "Target section by header line number" },
        .{ .long = "section", .kind = .string, .description = "Target section by tag name (default: resource)" },
    } ++ save_options;
    const batch_options = [_]spec.OptionSpec{
        project_root_opt,
    };
    const retarget_options = [_]spec.OptionSpec{
        .{ .long = "from", .kind = .string, .description = "Current ext_resource path (res://…)" },
        .{ .long = "to", .kind = .string, .description = "New ext_resource path (res://…)" },
        .{ .long = "project-root", .kind = .path, .description = "Godot project root for res:// seed path" },
        .{ .long = "resource-path", .kind = .string, .description = "Godot res:// path for ID seeding" },
        .{ .long = "no-prepare-save", .kind = .flag, .description = "Skip Godot save preparation on write" },
        .{ .long = "output", .kind = .path, .description = "Output path when processing a single file" },
        .{ .long = "dry-run", .kind = .flag, .description = "Report changes without writing" },
    } ++ id_session_options;
    const roundtrip_options = [_]spec.OptionSpec{
        .{ .long = "output", .kind = .path, .description = "Output path (default: overwrite input)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Check structure preservation without writing" },
    };
    const compare_godot_options = [_]spec.OptionSpec{
        .{ .long = "reference", .kind = .path, .description = "Godot-saved reference file (default: second positional)" },
    };
    const inspect_options = [_]spec.OptionSpec{
        project_root_opt,
        .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" },
        .{ .long = "parse-properties", .kind = .flag, .description = "Include parsed property values in JSON output" },
        .{ .long = "no-parse-properties", .kind = .flag, .description = "Omit parsed properties (faster for large files)" },
    };

    return .{
        .name = "resource",
        .summary = "Inspect and edit Godot resource files",
        .children = &.{
            .{
                .name = "inspect",
                .summary = "Parse a .tres file and report structure and ID issues",
                .description = "Reads section headers, parsed properties (with --json), and runs ID validation.",
                .options = &inspect_options,
                .handler = resourceInspectHandler,
            },
            .{
                .name = "validate",
                .summary = "Validate resource IDs and references (fails on errors)",
                .options = &.{project_root_opt},
                .handler = resourceValidateHandler,
            },
            .{
                .name = "validate-batch",
                .summary = "Validate multiple resource files (aggregated JSON, exit 1 on any error)",
                .options = &batch_options,
                .handler = resourceValidateBatchHandler,
            },
            .{
                .name = "set-property",
                .summary = "Set a property on a resource section and save",
                .options = &set_property_options,
                .handler = resourceSetPropertyHandler,
            },
            .{
                .name = "normalize",
                .summary = "Repair scene-local IDs and sort ext_resource sections for save",
                .options = &save_options,
                .handler = resourceNormalizeHandler,
            },
            .{
                .name = "retarget-ext",
                .summary = "Replace ext_resource paths across one or more files",
                .options = &retarget_options,
                .handler = resourceRetargetExtHandler,
            },
            .{
                .name = "round-trip",
                .summary = "Parse and rewrite a resource file; fail if structure is not preserved",
                .options = &roundtrip_options,
                .handler = resourceRoundTripHandler,
            },
            .{
                .name = "compare-godot",
                .summary = "Compare a resource to a Godot headless save (semantic match)",
                .options = &compare_godot_options,
                .handler = resourceCompareGodotHandler,
            },
        },
    };
}
