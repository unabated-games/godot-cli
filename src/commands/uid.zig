const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const resource_uid = @import("../godot/resource_uid.zig");
const scene_id = @import("../godot/scene_id.zig");

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
        },
    };
}

test "uid command tree" {
    const tree = commands();
    try std.testing.expectEqualStrings("uid", tree.name);
    try std.testing.expectEqual(@as(usize, 5), tree.children.len);
}
