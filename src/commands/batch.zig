const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const cli_batch = @import("../godot/cli_batch.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn batchHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);

    const batch_bytes: []const u8 = blk: {
        if (inv.getOption("file")) |path| {
            break :blk std.Io.Dir.cwd().readFileAlloc(cli.io, path, cli.allocator, .unlimited) catch return error.Io;
        }
        if (inv.getOption("json-body")) |text| {
            break :blk try cli.allocator.dupe(u8, text);
        }
        return error.Usage;
    };
    defer cli.allocator.free(batch_bytes);

    var batch_result = try cli_batch.runBatch(cli, batch_bytes, inv.global.json_output);
    defer batch_result.deinit(cli.allocator);

    var steps_json = std.json.Array.init(cli.allocator);
    for (batch_result.steps) |*step| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "index", .{ .integer = @intCast(step.index) });
        try row.put(cli.allocator, "argv", .{ .string = try cli.allocator.dupe(u8, step.argv) });
        try row.put(cli.allocator, "ok", .{ .bool = step.ok });
        if (step.error_name) |name| {
            try row.put(cli.allocator, "error", .{ .string = try cli.allocator.dupe(u8, name) });
        }
        if (step.data != .null) {
            try row.put(cli.allocator, "data", step.data);
        }
        try steps_json.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "mode", .{ .string = try cli.allocator.dupe(u8, batch_result.mode) });
    try data.put(cli.allocator, "step_count", .{ .integer = @intCast(batch_result.step_count) });
    try data.put(cli.allocator, "succeeded_count", .{ .integer = @intCast(batch_result.succeeded_count) });
    try data.put(cli.allocator, "failed_count", .{ .integer = @intCast(batch_result.failed_count) });
    try data.put(cli.allocator, "rolled_back", .{ .bool = batch_result.rolled_back });
    try data.put(cli.allocator, "steps", .{ .array = steps_json });

    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "batch {s}: {d}/{d} step(s) succeeded",
        .{ batch_result.mode, batch_result.succeeded_count, batch_result.step_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    const exit_code: spec.ExitCode = if (batch_result.failed_count > 0) .failure else .success;
    return .{ .data = .{ .object = data }, .messages = &.{}, .exit_code = exit_code };
}

pub fn commands() spec.CommandSpec {
    const batch_options = [_]spec.OptionSpec{
        .{ .long = "file", .kind = .path, .description = "Batch JSON file with mode, rollback, and steps" },
        .{ .long = "json-body", .kind = .string, .description = "Batch JSON inline (use --file if your shell conflicts with global --request)" },
    };

    return .{
        .name = "batch",
        .summary = "Run multiple CLI commands in one invocation",
        .description = "Each step is a full argv array. Modes: stop (default), continue, atomic. See docs/agent_batch_commands.md.",
        .options = &batch_options,
        .handler = batchHandler,
    };
}
