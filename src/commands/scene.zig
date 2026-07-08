const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const resource_uid = @import("../godot/resource_uid.zig");
const uid_cache = @import("../godot/uid_cache.zig");
const text_format = @import("../godot/text_format/root.zig");
const id_validate = @import("../godot/id_validate.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn projectRootFrom(inv: *const spec.Invocation) ?[]const u8 {
    return inv.getOption("project-root");
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
        var cache_storage: ?uid_cache.Cache = null;
        if (projectRootFrom(inv)) |root| {
            const cache_path = try uid_cache.defaultCachePath(cli.allocator, root);
            defer cli.allocator.free(cache_path);
            cache_storage = uid_cache.loadFromFile(cli.allocator, cli.io, cache_path) catch |err| switch (err) {
                error.Io => null,
                else => return err,
            };
        }
        const cache_ptr: ?*const uid_cache.Cache = if (cache_storage) |*c| c else null;
        const report = try id_validate.validateDocument(cli.allocator, &doc, cache_ptr);

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

fn sceneInspectHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return inspectHandler(ctx, inv, "scene");
}

fn resourceInspectHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    return inspectHandler(ctx, inv, "resource");
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
    return .{
        .name = "scene",
        .summary = "Inspect and edit Godot scene files",
        .children = &.{
            .{
                .name = "inspect",
                .summary = "Parse a .tscn file and report structure and ID issues",
                .description = "Reads section headers and runs ID validation. Pass --project-root to check uids against uid_cache.bin.",
                .options = &.{
                    .{ .long = "project-root", .kind = .path, .description = "Godot project root for uid_cache lookup" },
                    .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" },
                },
                .handler = sceneInspectHandler,
            },
        },
    };
}

pub fn resourceCommands() spec.CommandSpec {
    return .{
        .name = "resource",
        .summary = "Inspect and edit Godot resource files",
        .children = &.{
            .{
                .name = "inspect",
                .summary = "Parse a .tres file and report structure and ID issues",
                .options = &.{
                    .{ .long = "project-root", .kind = .path, .description = "Godot project root for uid_cache lookup" },
                    .{ .long = "no-validate", .kind = .flag, .description = "Skip ID validation" },
                },
                .handler = resourceInspectHandler,
            },
        },
    };
}
