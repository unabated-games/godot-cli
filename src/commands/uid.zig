const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const resource_uid = @import("../godot/resource_uid.zig");
const scene_id = @import("../godot/scene_id.zig");
const id_session = @import("../godot/id_session.zig");
const text_format = @import("../godot/text_format/root.zig");
const project_config = @import("../godot/project_config.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn uidEncodeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const raw = inv.positionals[0];
    const id = std.fmt.parseInt(i64, raw, 10) catch return error.Usage;
    const text = try resource_uid.idToText(cli.allocator, id);
    return .{
        .data = .{ .string = text },
        .messages = &.{text},
    };
}

fn uidDecodeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    _ = ctx;
    if (inv.positionals.len == 0) return error.Usage;
    const text = inv.positionals[0];
    const id = resource_uid.textToId(text);
    if (id == resource_uid.invalid_id) return error.Usage;
    return .{
        .data = .{ .integer = id },
        .messages = &.{text},
    };
}

fn uidCreateForPathHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const file_path = inv.positionals[0];
    const project_name = inv.getOption("project-name") orelse return error.Usage;
    const resource_path = inv.getOption("resource-path") orelse return error.Usage;

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, file_path, cli.allocator, .unlimited) catch return error.Io;
    const id = try resource_uid.createIdForPath(cli.allocator, project_name, resource_path, file_bytes);
    const text = try resource_uid.idToText(cli.allocator, id);

    var map: std.json.ObjectMap = .{};
    try map.put(cli.allocator, "id", .{ .integer = id });
    try map.put(cli.allocator, "uid", .{ .string = text });

    return .{
        .data = .{ .object = map },
        .messages = &.{text},
    };
}

fn uidSceneIdGenerateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const seed_raw = inv.getOption("seed") orelse return error.Usage;
    const seed = std.fmt.parseInt(u32, seed_raw, 10) catch return error.InvalidValue;
    const count_raw = inv.getOption("count") orelse "1";
    const count = std.fmt.parseInt(u32, count_raw, 10) catch return error.InvalidValue;

    scene_id.resetSceneUniqueIdGenerator();
    scene_id.seedSceneUniqueId(seed);

    var arr = std.json.Array.init(cli.allocator);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const generated = scene_id.generateSceneUniqueId();
        const copy = try cli.allocator.dupe(u8, &generated);
        try arr.append(.{ .string = copy });
    }

    return .{
        .data = .{ .array = arr },
        .messages = &.{},
    };
}

fn uidSessionImportHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const source_path = if (inv.getOption("from")) |path| path else blk: {
        if (inv.positionals.len == 0) return error.Usage;
        break :blk inv.positionals[0];
    };

    const referrer_path = if (inv.getOption("referrer")) |path|
        try cli.allocator.dupe(u8, path)
    else if (inv.getOption("project-root")) |root|
        try project_config.filesystemToResPath(cli.allocator, root, source_path) orelse return error.Usage
    else
        return error.Usage;

    const session_path = if (inv.getOption("id-session")) |path|
        try cli.allocator.dupe(u8, path)
    else if (inv.getOption("project-root")) |root|
        try id_session.Session.defaultPath(cli.allocator, root)
    else
        return error.Usage;

    var doc = try text_format.document.parseFile(cli.allocator, cli.io, source_path);
    defer doc.deinit(cli.allocator);

    var session = id_session.Session.loadFromFile(cli.allocator, session_path) catch id_session.Session.init(cli.allocator);
    defer session.deinit(cli.allocator);

    const imported = try session.importExtResourceIdsFromDocument(cli.allocator, referrer_path, &doc);
    try session.saveToFile(session_path);

    const summary = try std.fmt.allocPrint(cli.allocator, "imported {d} ext_resource id(s) for {s}", .{ imported, referrer_path });
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "referrer", .{ .string = referrer_path });
    try data.put(cli.allocator, "source", .{ .string = source_path });
    try data.put(cli.allocator, "session_path", .{ .string = session_path });
    try data.put(cli.allocator, "imported_count", .{ .integer = @intCast(imported) });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
    };
}

pub fn sessionCommands() spec.CommandSpec {
    const project_root_opt = spec.OptionSpec{
        .long = "project-root",
        .kind = .path,
        .description = "Godot project root (default session path under .godot/)",
    };
    const import_options = [_]spec.OptionSpec{
        .{ .long = "referrer", .kind = .string, .description = "Referrer res:// path (scene being saved)" },
        .{ .long = "from", .kind = .path, .description = "Godot-saved scene to import ids from" },
        .{ .long = "id-session", .kind = .path, .description = "Session cache JSON path" },
        project_root_opt,
    };

    return .{
        .name = "session",
        .summary = "Persistent ext_resource id session cache",
        .children = &.{
            .{
                .name = "import",
                .summary = "Import ext_resource ids from a Godot-saved scene",
                .description = "Updates scene_id_cache.json so future saves reuse Godot-assigned ext_resource ids.",
                .options = &import_options,
                .handler = uidSessionImportHandler,
            },
        },
    };
}

pub fn commands() spec.CommandSpec {
    return .{
        .name = "uid",
        .summary = "Godot-compatible resource and scene ID helpers",
        .children = &.{
            .{
                .name = "encode",
                .summary = "Encode a numeric Resource UID to uid:// text",
                .description = "Converts a 63-bit integer to Godot's uid:// representation.",
                .handler = uidEncodeHandler,
            },
            .{
                .name = "decode",
                .summary = "Decode uid:// text to a numeric Resource UID",
                .handler = uidDecodeHandler,
            },
            .{
                .name = "create-for-path",
                .summary = "Deterministic Resource UID for a project path and file",
                .description = "Matches ResourceUID.create_id_for_path using project name, Godot resource path, and file bytes.",
                .options = &.{
                    .{ .long = "project-name", .kind = .string, .description = "Project application/config/name" },
                    .{ .long = "resource-path", .kind = .string, .description = "Godot path e.g. res://main.tscn" },
                },
                .handler = uidCreateForPathHandler,
            },
            .{
                .name = "scene-id",
                .summary = "Scene-local 5-character unique id helpers",
                .children = &.{
                    .{
                        .name = "generate",
                        .summary = "Generate scene unique ids with a deterministic seed",
                        .options = &.{
                            .{ .long = "seed", .kind = .string, .description = "32-bit seed (e.g. path.hash() from Godot)" },
                            .{ .long = "count", .kind = .string, .description = "Number of ids to generate (default 1)" },
                        },
                        .handler = uidSceneIdGenerateHandler,
                    },
                },
            },
            @import("scene.zig").uidCacheCommands(),
            sessionCommands(),
        },
    };
}

test "uid command tree" {
    const tree = commands();
    try std.testing.expectEqualStrings("uid", tree.name);
    try std.testing.expectEqual(@as(usize, 6), tree.children.len);
}
