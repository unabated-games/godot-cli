const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const catalog_add = @import("../godot/catalog_add.zig");
const catalog_relink = @import("../godot/catalog_relink.zig");
const catalog_scan = @import("../godot/catalog_scan.zig");
const catalog_show = @import("../godot/catalog_show.zig");
const catalog_search = @import("../godot/catalog_search.zig");
const catalog_export = @import("../godot/catalog_export.zig");
const node_tree = @import("../godot/node_tree.zig");
const uid_cache = @import("../godot/uid_cache.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn projectRootFrom(inv: *const spec.Invocation) ?[]const u8 {
    return inv.getOption("project-root");
}

fn loadUidCacheOptional(cli: *const app_mod.App, project_root: []const u8) !?uid_cache.Cache {
    const cache_path = try uid_cache.defaultCachePath(cli.allocator, project_root);
    defer cli.allocator.free(cache_path);
    const loaded = uid_cache.loadFromFile(cli.allocator, cli.io, cache_path) catch return null;
    return loaded;
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const copy = try allocator.dupe(u8, text);
    return .{ .string = copy };
}

fn buildDocRowsJson(allocator: std.mem.Allocator, rows: []const catalog_scan.DocRow, is_signal: bool) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (rows) |row| {
        var obj: std.json.ObjectMap = .{};
        try obj.put(allocator, "name", try jsonString(allocator, row.name));
        try obj.put(allocator, "doc", try jsonString(allocator, row.doc));
        if (is_signal) {
            try obj.put(allocator, "connect_example", try jsonString(allocator, row.connect_example));
        } else {
            try obj.put(allocator, "when_to_call", try jsonString(allocator, row.when_to_call));
        }
        try arr.append(.{ .object = obj });
    }
    return arr;
}

fn buildStringArrayJson(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (items) |item| {
        try arr.append(try jsonString(allocator, item));
    }
    return arr;
}

fn buildIssuesJson(allocator: std.mem.Allocator, issues: []const catalog_scan.Issue) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (issues) |issue| {
        var obj: std.json.ObjectMap = .{};
        try obj.put(allocator, "severity", try jsonString(allocator, issue.severity.jsonString()));
        try obj.put(allocator, "code", try jsonString(allocator, issue.code));
        try obj.put(allocator, "message", try jsonString(allocator, issue.message));
        try arr.append(.{ .object = obj });
    }
    return arr;
}

fn buildEntryJson(allocator: std.mem.Allocator, entry: *const catalog_scan.ManifestEntry) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "manifest_path", try jsonString(allocator, entry.manifest_path));
    if (entry.manifest_res_path) |res_path| {
        try obj.put(allocator, "manifest_res_path", try jsonString(allocator, res_path));
    }
    try obj.put(allocator, "catalog_format_version", .{ .integer = entry.catalog_format_version });
    try obj.put(allocator, "id", try jsonString(allocator, entry.id));
    try obj.put(allocator, "scene", try jsonString(allocator, entry.scene));
    try obj.put(allocator, "scene_uid", try jsonString(allocator, entry.scene_uid));
    try obj.put(allocator, "tags", .{ .array = try buildStringArrayJson(allocator, entry.tags) });
    try obj.put(allocator, "summary", try jsonString(allocator, entry.summary));
    try obj.put(allocator, "when_to_use", try jsonString(allocator, entry.when_to_use));
    try obj.put(allocator, "when_not_to_use", try jsonString(allocator, entry.when_not_to_use));
    try obj.put(allocator, "related_ids", .{ .array = try buildStringArrayJson(allocator, entry.related_ids) });
    try obj.put(allocator, "prefer_over_ids", .{ .array = try buildStringArrayJson(allocator, entry.prefer_over_ids) });
    try obj.put(allocator, "notes", try jsonString(allocator, entry.notes));
    try obj.put(allocator, "export_root_script", try jsonString(allocator, entry.export_root_script));
    try obj.put(allocator, "signal_docs", .{ .array = try buildDocRowsJson(allocator, entry.signal_docs, true) });
    try obj.put(allocator, "function_docs", .{ .array = try buildDocRowsJson(allocator, entry.function_docs, false) });
    try obj.put(allocator, "issues", .{ .array = try buildIssuesJson(allocator, entry.issues) });
    try obj.put(allocator, "valid", .{ .bool = entry.valid });
    return .{ .object = obj };
}

fn scanHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv) orelse return error.Usage;

    var result = try catalog_scan.scanProject(cli.allocator, cli.io, project_root);
    defer result.deinit(cli.allocator);

    var entries_json = std.json.Array.init(cli.allocator);
    var valid_count: usize = 0;
    for (result.entries) |*entry| {
        if (entry.valid) valid_count += 1;
        try entries_json.append(try buildEntryJson(cli.allocator, entry));
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "project_root", try jsonString(cli.allocator, result.project_root));
    try data.put(cli.allocator, "manifest_files_found", .{ .integer = @intCast(result.manifest_files_found) });
    try data.put(cli.allocator, "entry_count", .{ .integer = @intCast(result.entries.len) });
    try data.put(cli.allocator, "valid_entry_count", .{ .integer = @intCast(valid_count) });
    try data.put(cli.allocator, "entries", .{ .array = entries_json });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "catalog: found {d} manifest(s), {d} valid",
        .{ result.entries.len, valid_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

fn buildShowJson(allocator: std.mem.Allocator, shown: *const catalog_show.ShowResult) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "id", try jsonString(allocator, shown.id));
    try obj.put(allocator, "source", try jsonString(allocator, shown.source));
    try obj.put(allocator, "exports_source", try jsonString(allocator, shown.exports_source));
    try obj.put(allocator, "script_parse_complete", .{ .bool = shown.script_parse_complete });

    if (shown.manifest) |*entry| {
        try obj.put(allocator, "manifest", try buildEntryJson(allocator, entry));
    }
    if (shown.builtin) |*entry| {
        var builtin_obj: std.json.ObjectMap = .{};
        try builtin_obj.put(allocator, "id", try jsonString(allocator, entry.id));
        try builtin_obj.put(allocator, "class_name", try jsonString(allocator, entry.class_name));
        try builtin_obj.put(allocator, "inherits", try jsonString(allocator, entry.inherits));
        try builtin_obj.put(allocator, "summary", try jsonString(allocator, entry.summary));
        try builtin_obj.put(allocator, "when_to_use", try jsonString(allocator, entry.when_to_use));
        try builtin_obj.put(allocator, "when_not_to_use", try jsonString(allocator, entry.when_not_to_use));
        try builtin_obj.put(allocator, "tags", .{ .array = try buildStringArrayJson(allocator, entry.tags) });
        try builtin_obj.put(allocator, "related_ids", .{ .array = try buildStringArrayJson(allocator, entry.related_ids) });
        try obj.put(allocator, "builtin", .{ .object = builtin_obj });
    }

    var exports_json = std.json.Array.init(allocator);
    for (shown.exports) |*export_info| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "name", try jsonString(allocator, export_info.name));
        try row.put(allocator, "type_hint", try jsonString(allocator, export_info.type_hint));
        try row.put(allocator, "default", try jsonString(allocator, export_info.default_value));
        try row.put(allocator, "group", try jsonString(allocator, export_info.group));
        try row.put(allocator, "export_annotations", .{ .array = try buildStringArrayJson(allocator, export_info.annotations) });
        try exports_json.append(.{ .object = row });
    }
    try obj.put(allocator, "exports", .{ .array = exports_json });

    var signals_json = std.json.Array.init(allocator);
    for (shown.signals) |*signal_info| {
        var row: std.json.ObjectMap = .{};
        try row.put(allocator, "name", try jsonString(allocator, signal_info.name));
        try row.put(allocator, "args", try jsonString(allocator, signal_info.args));
        try row.put(allocator, "doc", try jsonString(allocator, signal_info.doc));
        try row.put(allocator, "connect_example", try jsonString(allocator, signal_info.connect_example));
        try row.put(allocator, "doc_source", try jsonString(allocator, signal_info.doc_source));
        try signals_json.append(.{ .object = row });
    }
    try obj.put(allocator, "signals", .{ .array = signals_json });

    if (shown.scene) |*scene| {
        var scene_obj: std.json.ObjectMap = .{};
        try scene_obj.put(allocator, "scene", try jsonString(allocator, scene.scene_res_path));
        try scene_obj.put(allocator, "filesystem_path", try jsonString(allocator, scene.scene_filesystem_path));
        try scene_obj.put(allocator, "root_node_name", try jsonString(allocator, scene.root_node_name));
        try scene_obj.put(allocator, "root_node_type", try jsonString(allocator, scene.root_node_type));
        try scene_obj.put(allocator, "root_script", try jsonString(allocator, scene.root_script_res_path));
        try scene_obj.put(allocator, "root_script_filesystem_path", try jsonString(allocator, scene.root_script_filesystem_path));
        try scene_obj.put(allocator, "nodes", .{ .array = try node_tree.nodesToJsonArray(allocator, scene.nodes.nodes) });
        try obj.put(allocator, "scene", .{ .object = scene_obj });
    }

    return .{ .object = obj };
}

fn parseTagsOption(allocator: std.mem.Allocator, text: ?[]const u8) ![]const []const u8 {
    const raw = text orelse return &.{};
    if (raw.len == 0) return &.{};
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    var parts = std.mem.tokenizeAny(u8, raw, ",");
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try items.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return try items.toOwnedSlice(allocator);
}

fn addHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv) orelse return error.Usage;

    const tags = try parseTagsOption(cli.allocator, inv.getOption("tags"));
    defer freeStringList(cli.allocator, tags);
    const related = try parseTagsOption(cli.allocator, inv.getOption("related-ids"));
    defer freeStringList(cli.allocator, related);

    var result = try catalog_add.addManifest(cli.allocator, cli.io, project_root, .{
        .scene = inv.positionals[0],
        .id = inv.getOption("id"),
        .summary = inv.getOption("summary"),
        .when_to_use = inv.getOption("when-to-use"),
        .when_not_to_use = inv.getOption("when-not-to-use"),
        .notes = inv.getOption("notes"),
        .tags = tags,
        .related_ids = related,
        .update = inv.flag("update"),
        .output = inv.getOption("output"),
        .dry_run = inv.flag("dry-run"),
    });
    defer result.deinit(cli.allocator);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "manifest_path", try jsonString(cli.allocator, result.manifest_path));
    try data.put(cli.allocator, "manifest_res_path", try jsonString(cli.allocator, result.manifest_res_path));
    try data.put(cli.allocator, "id", try jsonString(cli.allocator, result.id));
    try data.put(cli.allocator, "scene", try jsonString(cli.allocator, result.scene));
    try data.put(cli.allocator, "scene_uid", try jsonString(cli.allocator, result.scene_uid));
    try data.put(cli.allocator, "signals_scaffolded", .{ .integer = @intCast(result.signals_scaffolded) });
    try data.put(cli.allocator, "updated", .{ .bool = result.updated });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    if (inv.flag("dry-run")) {
        try data.put(cli.allocator, "manifest", try jsonString(cli.allocator, result.json));
    }

    const verb = if (result.updated) "updated" else "created";
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "{s} {s} for {s}",
        .{ verb, result.manifest_path, result.id },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn relinkHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv) orelse return error.Usage;
    const dry_run = inv.flag("dry-run");

    var owned_cache: ?uid_cache.Cache = null;
    defer if (owned_cache) |*cache| cache.deinit(cli.allocator);
    if (loadUidCacheOptional(cli, project_root)) |maybe_cache| {
        owned_cache = maybe_cache;
    } else |_| {}

    var result = try catalog_relink.relinkProject(
        cli.allocator,
        cli.io,
        project_root,
        if (owned_cache) |*cache| cache else null,
        dry_run,
    );
    defer result.deinit(cli.allocator);

    var entries_json = std.json.Array.init(cli.allocator);
    for (result.entries) |entry| {
        var obj: std.json.ObjectMap = .{};
        try obj.put(cli.allocator, "id", try jsonString(cli.allocator, entry.id));
        try obj.put(cli.allocator, "manifest_path", try jsonString(cli.allocator, entry.manifest_path));
        try obj.put(cli.allocator, "status", try jsonString(cli.allocator, entry.status.jsonString()));
        try obj.put(cli.allocator, "scene", try jsonString(cli.allocator, entry.old_scene));
        if (entry.new_scene.len > 0) {
            try obj.put(cli.allocator, "new_scene", try jsonString(cli.allocator, entry.new_scene));
        }
        if (entry.reason.len > 0) {
            try obj.put(cli.allocator, "reason", try jsonString(cli.allocator, entry.reason));
        }
        try entries_json.append(.{ .object = obj });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "project_root", try jsonString(cli.allocator, result.project_root));
    try data.put(cli.allocator, "checked", .{ .integer = @intCast(result.checked) });
    try data.put(cli.allocator, "relinked", .{ .integer = @intCast(result.relinked) });
    try data.put(cli.allocator, "unresolved", .{ .integer = @intCast(result.unresolved) });
    try data.put(cli.allocator, "dry_run", .{ .bool = dry_run });
    try data.put(cli.allocator, "entries", .{ .array = entries_json });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "catalog relink: {d} checked, {d} relinked, {d} unresolved{s}",
        .{
            result.checked,
            result.relinked,
            result.unresolved,
            if (dry_run) " (dry run)" else "",
        },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
        // Anything still pointing at a missing scene keeps this failing, so a
        // relink step in CI does not go green on a half-repair.
        .exit_code = if (result.hasUnrepaired()) .failure else null,
    };
}

fn showHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const id = inv.positionals[0];
    const project_root = projectRootFrom(inv);

    var owned_cache: ?uid_cache.Cache = null;
    defer if (owned_cache) |*cache| cache.deinit(cli.allocator);
    if (project_root) |root| {
        if (loadUidCacheOptional(cli, root)) |maybe_cache| {
            owned_cache = maybe_cache;
        } else |_| {}
    }

    var shown = try catalog_show.showById(
        cli.allocator,
        cli.io,
        project_root,
        if (owned_cache) |*cache| cache else null,
        id,
    );
    defer shown.deinit(cli.allocator);

    const data = try buildShowJson(cli.allocator, &shown);
    const summary = try std.fmt.allocPrint(cli.allocator, "catalog: {s} ({s})", .{ shown.id, shown.source });
    var root: std.json.ObjectMap = .{};
    try root.put(cli.allocator, "summary", .{ .string = summary });
    try root.put(cli.allocator, "entry", data);

    return .{
        .data = .{ .object = root },
        .messages = &.{summary},
    };
}

fn validateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv) orelse return error.Usage;

    var owned_cache: ?uid_cache.Cache = null;
    defer if (owned_cache) |*cache| cache.deinit(cli.allocator);
    if (loadUidCacheOptional(cli, project_root)) |maybe_cache| {
        owned_cache = maybe_cache;
    } else |_| {}

    var result = try catalog_scan.scanProject(cli.allocator, cli.io, project_root);
    defer result.deinit(cli.allocator);

    var error_count: usize = 0;
    var warning_count: usize = 0;
    var entries_json = std.json.Array.init(cli.allocator);
    for (result.entries) |*entry| {
        for (entry.issues) |issue| {
            switch (issue.severity) {
                .@"error" => error_count += 1,
                .warning => warning_count += 1,
                .info => {},
            }
        }
        try entries_json.append(try buildEntryJson(cli.allocator, entry));
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "project_root", try jsonString(cli.allocator, result.project_root));
    try data.put(cli.allocator, "entry_count", .{ .integer = @intCast(result.entries.len) });
    try data.put(cli.allocator, "error_count", .{ .integer = @intCast(error_count) });
    try data.put(cli.allocator, "warning_count", .{ .integer = @intCast(warning_count) });
    try data.put(cli.allocator, "valid", .{ .bool = error_count == 0 });
    try data.put(cli.allocator, "entries", .{ .array = entries_json });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "catalog validate: {d} error(s), {d} warning(s)",
        .{ error_count, warning_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    if (error_count > 0) {
        return .{
            .data = .{ .object = data },
            .messages = &.{summary},
            .exit_code = .failure,
        };
    }
    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

fn exportHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv) orelse return error.Usage;
    const output_rel = inv.getOption("output") orelse "AGENTS.md";
    const output_path = blk: {
        if (std.fs.path.isAbsolute(output_rel)) {
            break :blk try cli.allocator.dupe(u8, output_rel);
        }
        break :blk try std.fs.path.join(cli.allocator, &.{ project_root, output_rel });
    };
    defer cli.allocator.free(output_path);
    const dry_run = inv.flag("dry-run");

    var owned_cache: ?uid_cache.Cache = null;
    defer if (owned_cache) |*cache| cache.deinit(cli.allocator);
    if (loadUidCacheOptional(cli, project_root)) |maybe_cache| {
        owned_cache = maybe_cache;
    } else |_| {}

    var result = try catalog_export.exportCatalog(
        cli.allocator,
        cli.io,
        project_root,
        if (owned_cache) |*cache| cache else null,
        output_path,
        dry_run,
    );
    defer result.deinit(cli.allocator);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "project_root", try jsonString(cli.allocator, result.project_root));
    try data.put(cli.allocator, "output_path", try jsonString(cli.allocator, result.output_path));
    try data.put(cli.allocator, "project_entry_count", .{ .integer = @intCast(result.project_entry_count) });
    try data.put(cli.allocator, "builtin_entry_count", .{ .integer = @intCast(result.builtin_entry_count) });
    try data.put(cli.allocator, "skipped_invalid_count", .{ .integer = @intCast(result.skipped_invalid_count) });
    try data.put(cli.allocator, "wrote_file", .{ .bool = result.wrote_file });
    try data.put(cli.allocator, "dry_run", .{ .bool = dry_run });
    try data.put(cli.allocator, "markdown", try jsonString(cli.allocator, result.markdown));

    const summary = if (dry_run)
        try std.fmt.allocPrint(
            cli.allocator,
            "catalog export: {d} project + {d} builtin entries (dry run)",
            .{ result.project_entry_count, result.builtin_entry_count },
        )
    else
        try std.fmt.allocPrint(
            cli.allocator,
            "catalog export: wrote {s} ({d} project + {d} builtin entries)",
            .{ result.output_path, result.project_entry_count, result.builtin_entry_count },
        );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

fn searchHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const project_root = projectRootFrom(inv);
    const query = inv.getOption("query") orelse "";
    const tags_text = inv.getOption("tags");

    const owned_tags = try parseTagsOption(cli.allocator, tags_text);
    defer {
        for (owned_tags) |tag| cli.allocator.free(tag);
        cli.allocator.free(owned_tags);
    }

    var result = try catalog_search.searchCatalog(
        cli.allocator,
        cli.io,
        project_root,
        owned_tags,
        query,
    );
    defer result.deinit(cli.allocator);

    var hits_json = std.json.Array.init(cli.allocator);
    for (result.hits) |*hit| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "id", try jsonString(cli.allocator, hit.id));
        try row.put(cli.allocator, "source", try jsonString(cli.allocator, hit.source));
        try row.put(cli.allocator, "summary", try jsonString(cli.allocator, hit.summary));
        try row.put(cli.allocator, "tags", .{ .array = try buildStringArrayJson(cli.allocator, hit.tags) });
        try row.put(cli.allocator, "score", .{ .integer = @intCast(hit.score) });
        try hits_json.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "query", try jsonString(cli.allocator, result.query));
    try data.put(cli.allocator, "tags", .{ .array = try buildStringArrayJson(cli.allocator, result.tags) });
    try data.put(cli.allocator, "hit_count", .{ .integer = @intCast(result.hits.len) });
    try data.put(cli.allocator, "hits", .{ .array = hits_json });

    const summary = try std.fmt.allocPrint(cli.allocator, "catalog search: {d} hit(s)", .{result.hits.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

fn listHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const scan = try scanHandler(ctx, inv);
    const cli = appFrom(ctx);

    const all_entries = scan.data.object.get("entries").?.array;
    var listed = std.json.Array.init(cli.allocator);
    for (all_entries.items) |entry_value| {
        const entry_obj = entry_value.object;
        if (!entry_obj.get("valid").?.bool) continue;
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "id", entry_obj.get("id").?);
        try row.put(cli.allocator, "scene", entry_obj.get("scene").?);
        try row.put(cli.allocator, "summary", entry_obj.get("summary").?);
        try row.put(cli.allocator, "tags", entry_obj.get("tags").?);
        if (entry_obj.get("manifest_res_path")) |res_path| {
            try row.put(cli.allocator, "manifest_res_path", res_path);
        }
        try listed.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "project_root", scan.data.object.get("project_root").?);
    try data.put(cli.allocator, "entry_count", .{ .integer = @intCast(listed.items.len) });
    try data.put(cli.allocator, "entries", .{ .array = listed });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "catalog: {d} valid entries",
        .{listed.items.len},
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{summary},
    };
}

pub fn commands() spec.CommandSpec {
    const project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root (directory containing project.godot)",
    };

    const tags_opt = spec.OptionSpec{
        .long = "tags",
        .kind = .string,
        .description = "Comma-separated tag filter (all tags must match)",
    };
    const query_opt = spec.OptionSpec{
        .long = "query",
        .kind = .string,
        .description = "Free-text search across summaries and docs",
    };
    const output_opt = spec.OptionSpec{
        .long = "output",
        .kind = .path,
        .description = "Output markdown path relative to project root (default: AGENTS.md)",
    };
    const dry_run_opt = spec.OptionSpec{
        .long = "dry-run",
        .kind = .flag,
        .description = "Generate markdown without writing the output file",
    };

    const add_options = [_]spec.OptionSpec{
        project_root_opt,
        .{ .long = "id", .kind = .string, .description = "Catalog id (default: scene path without res:// and extension)" },
        .{ .long = "summary", .kind = .string, .description = "One-line description of the component" },
        .{ .long = "when-to-use", .kind = .string, .description = "When an agent should reach for this component" },
        .{ .long = "when-not-to-use", .kind = .string, .description = "When an agent should use something else" },
        .{ .long = "notes", .kind = .string, .description = "Edge cases and variant notes" },
        .{ .long = "tags", .kind = .string, .description = "Comma-separated tags" },
        .{ .long = "related-ids", .kind = .string, .description = "Comma-separated related catalog ids" },
        .{ .long = "update", .kind = .flag, .description = "Update an existing manifest, keeping prose already written" },
        .{ .long = "output", .kind = .path, .description = "Manifest path (default: <scene>.manifest.json beside the scene)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Render the manifest without writing it" },
    };

    return .{
        .name = "catalog",
        .summary = "Project component catalog",
        .description = "Create, scan, list, show, validate, search, and export catalog manifests describing project components for LLM agents.",
        .children = &.{
            .{
                .name = "add",
                .summary = "Create or update a JSON catalog manifest for a scene",
                .description = "Writes <scene>.manifest.json beside the scene, filling scene_uid from the scene header and scaffolding a row for each signal declared by the root script. With --update, prose already written is preserved.",
                .options = &add_options,
                .handler = addHandler,
            },
            .{
                .name = "relink",
                .summary = "Repoint manifests whose scene has moved",
                .description = "For every manifest whose scene file is missing, resolves its scene_uid through .godot/uid_cache.bin and rewrites the scene path. Requires the project to have been opened in Godot since the move, since the editor is what refreshes that cache. Exits 1 if any manifest is still unrepaired.",
                .options = &.{
                    project_root_opt,
                    .{ .long = "dry-run", .kind = .flag, .description = "Report which manifests would be repointed without writing them" },
                },
                .handler = relinkHandler,
            },
            .{
                .name = "scan",
                .summary = "Scan project for catalog manifests",
                .description = "Walks the project for *.manifest.json, parses fields, and validates catalog entries.",
                .options = &.{project_root_opt},
                .handler = scanHandler,
            },
            .{
                .name = "list",
                .summary = "List valid catalog entries",
                .description = "Runs catalog scan and returns valid entries only (id, scene, summary, tags).",
                .options = &.{project_root_opt},
                .handler = listHandler,
            },
            .{
                .name = "show",
                .summary = "Show merged catalog entry by id",
                .description = "Returns manifest fields merged with scene nodes and GDScript exports/signals. Builtin ids use the godot/ namespace.",
                .options = &.{project_root_opt},
                .handler = showHandler,
            },
            .{
                .name = "validate",
                .summary = "Validate catalog manifests in a project",
                .description = "Runs catalog scan and fails when any manifest has validation errors.",
                .options = &.{project_root_opt},
                .handler = validateHandler,
            },
            .{
                .name = "search",
                .summary = "Search project catalog entries and builtins",
                .description = "Filter by tags and/or free-text query across summaries and documentation fields.",
                .options = &.{ project_root_opt, tags_opt, query_opt },
                .handler = searchHandler,
            },
            .{
                .name = "export",
                .summary = "Export agent digest markdown",
                .description = "Writes a markdown catalog digest for LLM agents (default: AGENTS.md in the project root).",
                .options = &.{ project_root_opt, output_opt, dry_run_opt },
                .handler = exportHandler,
            },
        },
    };
}
