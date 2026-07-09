const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const project_godot = @import("../godot/project_godot.zig");
const project_input = @import("../godot/project_input.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn projectRootFrom(inv: *const spec.Invocation) ?[]const u8 {
    return inv.getOption("project-root");
}

fn projectGodotPath(allocator: std.mem.Allocator, project_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ project_root, "project.godot" });
}

fn loadProject(cli: *const app_mod.App, inv: *const spec.Invocation) !struct {
    path: []const u8,
    doc: project_godot.Document,
} {
    const root = projectRootFrom(inv) orelse return error.Usage;
    const path = try projectGodotPath(cli.allocator, root);
    errdefer cli.allocator.free(path);
    const doc = try project_godot.readFile(cli.allocator, cli.io, path);
    return .{ .path = path, .doc = doc };
}

fn inputListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const input = loaded.doc.sectionMut("input") orelse {
        var data: std.json.ObjectMap = .{};
        const empty_actions = std.json.Array.init(cli.allocator);
        try data.put(cli.allocator, "actions", .{ .array = empty_actions });
        try data.put(cli.allocator, "action_count", .{ .integer = 0 });
        try data.put(cli.allocator, "summary", .{ .string = "no [input] section" });
        return .{ .data = .{ .object = data }, .messages = &.{} };
    };

    const actions = try project_input.listActions(cli.allocator, input);
    defer {
        for (actions) |*action| action.deinit(cli.allocator);
        cli.allocator.free(actions);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (actions) |action| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, action.name) });
        try row.put(cli.allocator, "deadzone", .{ .float = action.deadzone });
        try row.put(cli.allocator, "event_count", .{ .integer = @intCast(action.event_count) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "actions", .{ .array = arr });
    try data.put(cli.allocator, "action_count", .{ .integer = @intCast(actions.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} input action(s)", .{actions.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn inputApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_input.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var names = std.json.Array.init(cli.allocator);
    for (applied.applied_actions) |name| {
        try names.append(.{ .string = try cli.allocator.dupe(u8, name) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_actions", .{ .array = names });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "applied {d} input action(s) ({d} added, {d} replaced)",
        .{ applied.applied_actions.len, applied.added_count, applied.replaced_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn inputValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const input = loaded.doc.sectionMut("input");
    const issue_count = if (input) |section|
        try project_input.validateInputSection(cli.allocator, section)
    else
        @as(usize, 0);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "input map: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

pub fn commands() spec.CommandSpec {
    const project_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
    };

    const input_apply_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "intent", .kind = .path, .description = "Input map intent JSON (actions + events)" },
        .{ .long = "file", .kind = .path, .description = "Alias for --intent" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    return .{
        .name = "project",
        .summary = "Read and write Godot project.godot settings",
        .description = "Project-level configuration (Input Map today; autoloads and other sections planned).",
        .options = &project_options,
        .children = &.{
            .{
                .name = "input",
                .summary = "Input Map actions in project.godot",
                .children = &.{
                    .{
                        .name = "list",
                        .summary = "List input actions",
                        .options = &project_options,
                        .handler = inputListHandler,
                    },
                    .{
                        .name = "apply",
                        .summary = "Apply input map intent JSON (merge/replace per action)",
                        .options = &input_apply_options,
                        .handler = inputApplyHandler,
                    },
                    .{
                        .name = "validate",
                        .summary = "Validate [input] section event objects",
                        .options = &project_options,
                        .handler = inputValidateHandler,
                    },
                },
            },
        },
    };
}
