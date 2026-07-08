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

    pub fn persistSession(self: *PreparedSave, allocator: std.mem.Allocator) !void {
        if (self.session_path) |path| {
            if (self.session) |session| try session.saveToFile(path);
        }
        _ = allocator;
    }
};

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

    const written_value: []const u8 = if (inv.flag("raw-value")) property_value else blk: {
        const parsed = try variant.parse.parsePropertyValue(cli.allocator, property_value);
        defer cli.allocator.free(parsed.raw);
        break :blk try parsed.formatForWrite(cli.allocator);
    };
    if (!inv.flag("raw-value")) {
        defer cli.allocator.free(written_value);
    }

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

fn inspectHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];
    const validate = !inv.flag("no-validate");

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

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

fn normalizeHandler(ctx: *anyopaque, inv: *const spec.Invocation, kind: []const u8) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const input_path = inv.positionals[0];
    const output_path = inv.getOption("output") orelse input_path;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, input_path);
    var prepare = try prepareSaveOptions(cli, inv, output_path);
    defer prepare.deinit(cli.allocator);
    if (!inv.flag("dry-run")) {
        try text_format.writer.writeFile(cli.allocator, output_path, &doc, prepare.options);
        try prepare.persistSession(cli.allocator);
    } else if (prepare.options) |options| {
        try text_format.save_prepare.prepareDocument(cli.allocator, &doc, options);
    }

    const summary = try std.fmt.allocPrint(cli.allocator, "prepared {s} save for {s}", .{ kind, output_path });
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = output_path });
    try data.put(cli.allocator, "kind", .{ .string = kind });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
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

    return .{
        .name = "scene",
        .summary = "Inspect and edit Godot scene files",
        .children = &.{
            .{
                .name = "inspect",
                .summary = "Parse a .tscn file and report structure and ID issues",
                .description = "Reads section headers and runs ID validation. Pass --project-root to check uids against uid_cache.bin.",
                .options = &.{ project_root_opt, .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" } },
                .handler = sceneInspectHandler,
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

    return .{
        .name = "resource",
        .summary = "Inspect and edit Godot resource files",
        .children = &.{
            .{
                .name = "inspect",
                .summary = "Parse a .tres file and report structure and ID issues",
                .options = &.{ project_root_opt, .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" } },
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
