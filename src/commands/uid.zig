const std = @import("std");
const spec = @import("../cli/spec.zig");
const pos = @import("positionals.zig");
const app_mod = @import("../cli/app.zig");
const resource_uid = @import("../godot/resource_uid.zig");
const scene_id = @import("../godot/scene_id.zig");
const id_session = @import("../godot/id_session.zig");
const text_format = @import("../godot/text_format/root.zig");
const project_config = @import("../godot/project_config.zig");
const binary_resource = @import("../godot/binary_resource.zig");
const resource_uid_lookup = @import("../godot/resource_uid_lookup.zig");
const error_details = @import("../godot/error_details.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

/// A resource UID's number as decimal text. It is 63 bits, and a JSON
/// parser that reads numbers as doubles, JavaScript's included, rounds it:
/// trial 30 was handed 5402782583183944000 for 5402782583183943612.
pub fn idNumberText(allocator: std.mem.Allocator, id: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

fn uidEncodeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const raw = inv.positionals[0];
    const id = std.fmt.parseInt(i64, raw, 10) catch return error.Usage;
    const text = try resource_uid.idToText(cli.allocator, id);
    return .{
        .data = .{ .string = text },
        .messages = try cli.allocator.dupe([]const u8, &.{text}),
    };
}

fn uidDecodeHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    if (inv.positionals.len == 0) return error.Usage;
    const text = inv.positionals[0];
    const id = resource_uid.textToId(text);
    if (id == resource_uid.invalid_id) return error.Usage;
    const number = try idNumberText(cli.allocator, id);
    return .{
        .data = .{ .string = number },
        .messages = try cli.allocator.dupe([]const u8, &.{number}),
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
    try map.put(cli.allocator, "id", .{ .string = try idNumberText(cli.allocator, id) });
    try map.put(cli.allocator, "uid", .{ .string = text });

    return .{
        .data = .{ .object = map },
        .messages = try cli.allocator.dupe([]const u8, &.{text}),
    };
}

/// The UID a file itself records, the way Godot finds it: a scene or resource
/// in its header, text or binary; a script in its `.uid` sidecar; an imported
/// asset in its `.import` file. No uid cache, so it works on a fresh clone.
fn uidReadHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const path = inv.positionals[0];

    std.Io.Dir.cwd().access(cli.io, path, .{}) catch {
        error_details.record(.{ .field = "file", .value = path });
        return error.FileNotFound;
    };

    var map: std.json.ObjectMap = .{};
    try map.put(cli.allocator, "path", .{ .string = path });

    var source: []const u8 = undefined;
    var missing_hint: []const u8 = undefined;
    const uid_text: ?[]const u8 = blk: {
        if (std.mem.endsWith(u8, path, ".tscn") or std.mem.endsWith(u8, path, ".tres")) {
            source = "text_header";
            missing_hint = "the [gd_scene] or [gd_resource] line has no uid attribute";
            const doc = text_format.document.parseFile(cli.allocator, cli.io, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    error_details.record(.{ .field = "file", .value = path, .hint = "not a readable Godot text scene or resource" });
                    return error.Io;
                },
            };
            if (doc.sections.items.len == 0) break :blk null;
            const header = &doc.sections.items[0].header;
            if (!std.mem.eql(u8, header.name, "gd_scene") and !std.mem.eql(u8, header.name, "gd_resource")) break :blk null;
            break :blk header.getString("uid");
        }
        if (binary_resource.isBinaryResourceFile(cli.io, path)) {
            source = "binary_header";
            missing_hint = "the binary header's UID slot is empty, so references to this file resolve by its res:// path";
            const header = binary_resource.readHeader(cli.allocator, cli.io, path) catch |err| {
                const hint: []const u8 = switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnsupportedCompression => "compressed with a mode other than zstd, which Godot's resource saver never writes",
                    error.UnsupportedVersion => "saved in a binary format newer than this godot-cli reads; upgrade godot-cli",
                    else => "the header is truncated or damaged",
                };
                error_details.record(.{ .field = "file", .value = path, .hint = hint });
                return error.BinaryResourceUnreadable;
            };
            try map.put(cli.allocator, "class", .{ .string = header.class_name });
            try map.put(cli.allocator, "compressed", .{ .bool = header.compressed });
            try map.put(cli.allocator, "godot_version", .{ .string = try std.fmt.allocPrint(cli.allocator, "{d}.{d}", .{ header.engine_major, header.engine_minor }) });
            try map.put(cli.allocator, "format_version", .{ .integer = header.format_version });
            const id = header.uid orelse break :blk null;
            break :blk try resource_uid.idToText(cli.allocator, id);
        }
        missing_hint = "no .uid sidecar or .import file beside it; Godot writes one when it imports the project (godot-cli project import)";
        if (resource_uid_lookup.readSidecarUid(cli.allocator, cli.io, path)) |uid| {
            source = "uid_sidecar";
            break :blk uid;
        }
        if (resource_uid_lookup.readImportFileUid(cli.allocator, cli.io, path)) |uid| {
            source = "import_file";
            break :blk uid;
        }
        break :blk null;
    };

    const text = uid_text orelse {
        error_details.record(.{ .field = "file", .value = path, .hint = missing_hint });
        return error.NoUidRecorded;
    };
    const id = resource_uid.textToId(text);
    if (id == resource_uid.invalid_id) {
        error_details.record(.{ .field = "uid", .value = text, .hint = "the recorded value is not valid uid:// text" });
        return error.NoUidRecorded;
    }
    // No numeric id: a 64-bit integer does not survive a JSON parser that
    // reads numbers as doubles, JavaScript's included. An agent in a trial was
    // handed 5402782583183944000 for 5402782583183943612 by its MCP client.
    // The uid:// text is the identifier and arrives exact; `uid decode` gives
    // the number to anyone who needs it.
    try map.put(cli.allocator, "uid", .{ .string = text });
    try map.put(cli.allocator, "source", .{ .string = source });

    return .{
        .data = .{ .object = map },
        .messages = try cli.allocator.dupe([]const u8, &.{text}),
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
        const generated = try scene_id.generateSceneUniqueId();
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
                .positionals = &pos.scene_file,
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
                .positionals = &pos.uid_id,
            },
            .{
                .name = "decode",
                .summary = "Decode uid:// text to a numeric Resource UID",
                .description = "The number comes back as a decimal string, not a JSON number: a UID is 63 bits, far past the 53 a JSON parser that reads numbers as doubles can hold, JavaScript's included, so such a parser would round it. Store it as a signed 64-bit integer or as text.",
                .handler = uidDecodeHandler,
                .positionals = &pos.uid_text,
            },
            .{
                .name = "create-for-path",
                .summary = "The UID Godot would assign a new file (to read a file's existing UID, use uid read)",
                .description = "Matches ResourceUID.create_id_for_path using project name, Godot resource path, and file bytes: the UID Godot would assign a file that has none. To find the UID a file already has, use uid read; a binary resource's never equals this. Result data: uid, and id as a decimal string, since a 63-bit number does not survive a JSON parser that reads numbers as doubles.",
                .options = &.{
                    .{ .long = "project-name", .kind = .string, .description = "Project application/config/name" },
                    .{ .long = "resource-path", .kind = .string, .description = "Godot path e.g. res://main.tscn" },
                },
                .handler = uidCreateForPathHandler,
                .positionals = &pos.file,
            },
            .{
                .name = "read",
                .summary = "Read the UID a file records, from the file itself",
                .description = "Needs no uid_cache.bin, so it works on a fresh clone. A scene or resource keeps its UID in its own header, binary (.res, .scn) or text (.tscn, .tres); a script keeps it in a .uid sidecar and an imported asset in its .import file. Fails with no_uid_recorded when the file records none. Result data: path, uid, source (text_header, binary_header, uid_sidecar or import_file), and for a binary resource its class, compressed, godot_version and format_version.",
                .handler = uidReadHandler,
                .positionals = &pos.uid_file,
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
    try std.testing.expectEqual(@as(usize, 7), tree.children.len);
}
