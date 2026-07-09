//! Execute multiple CLI invocations in one request (for LLM agents).

const std = @import("std");
const app_mod = @import("../cli/app.zig");
const spec = @import("../cli/spec.zig");
const scene_undo = @import("scene_undo.zig");

pub const Error = error{
    OutOfMemory,
    InvalidBatch,
    MissingBatchField,
    Io,
} || scene_undo.Error || spec.CliError;

pub const Mode = enum {
    stop,
    @"continue",
    atomic,

    pub fn fromString(text: []const u8) ?Mode {
        if (std.mem.eql(u8, text, "stop")) return .stop;
        if (std.mem.eql(u8, text, "continue")) return .@"continue";
        if (std.mem.eql(u8, text, "atomic")) return .atomic;
        return null;
    }

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .stop => "stop",
            .@"continue" => "continue",
            .atomic => "atomic",
        };
    }
};

pub const StepOutcome = struct {
    index: usize,
    argv: []const u8,
    ok: bool,
    error_name: ?[]const u8 = null,
    data: std.json.Value = .null,

    pub fn deinit(self: *StepOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        if (self.error_name) |name| allocator.free(name);
        _ = self.data;
    }
};

pub const BatchResult = struct {
    mode: []const u8,
    step_count: usize,
    succeeded_count: usize,
    failed_count: usize,
    rolled_back: bool,
    steps: []StepOutcome,

    pub fn deinit(self: *BatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

const RollbackSnapshot = struct {
    scene_path: []const u8,
    backup_path: []const u8,
};

pub fn runBatch(
    app: *const app_mod.App,
    batch_json: []const u8,
    json_output: bool,
) Error!BatchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, app.allocator, batch_json, .{}) catch return error.InvalidBatch;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidBatch;

    const mode = blk: {
        if (root.object.get("mode")) |mode_value| {
            const text = try jsonString(&mode_value);
            break :blk Mode.fromString(text) orelse return error.InvalidBatch;
        }
        break :blk Mode.stop;
    };

    var rollback_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (rollback_paths.items) |path| app.allocator.free(path);
        rollback_paths.deinit(app.allocator);
    }
    if (root.object.get("rollback")) |rollback_value| {
        try readStringArray(app.allocator, rollback_value, &rollback_paths);
    }

    const steps_value = root.object.get("steps") orelse return error.MissingBatchField;
    if (steps_value != .array) return error.InvalidBatch;

    var snapshots: std.ArrayList(RollbackSnapshot) = .empty;
    defer {
        for (snapshots.items) |item| {
            app.allocator.free(item.scene_path);
            app.allocator.free(item.backup_path);
        }
        snapshots.deinit(app.allocator);
    }

    if (mode == .atomic) {
        for (rollback_paths.items) |path| {
            const backup_path = try std.fmt.allocPrint(app.allocator, "{s}.godot-cli-batch-backup", .{path});
            errdefer app.allocator.free(backup_path);
            try scene_undo.writeSnapshot(app.io, path, backup_path);
            try snapshots.append(app.allocator, .{
                .scene_path = try app.allocator.dupe(u8, path),
                .backup_path = backup_path,
            });
        }
    }

    var outcomes: std.ArrayList(StepOutcome) = .empty;
    errdefer {
        for (outcomes.items) |*item| item.deinit(app.allocator);
        outcomes.deinit(app.allocator);
    }

    var succeeded: usize = 0;
    var failed: usize = 0;
    var rolled_back = false;
    var stop = false;

    for (steps_value.array.items, 0..) |*step_value, index| {
        if (stop) break;

        const argv = try readArgv(app.allocator, step_value);
        errdefer freeArgv(app.allocator, argv);

        const argv_summary = try argvToString(app.allocator, argv);
        errdefer app.allocator.free(argv_summary);

        const outcome = blk: {
            const result = app_mod.App.invoke(app, argv, json_output) catch |err| {
                break :blk StepOutcome{
                    .index = index,
                    .argv = argv_summary,
                    .ok = false,
                    .error_name = try app.allocator.dupe(u8, @errorName(err)),
                    .data = .null,
                };
            };

            if (result.exit_code) |code| {
                if (code != .success) {
                    break :blk StepOutcome{
                        .index = index,
                        .argv = argv_summary,
                        .ok = false,
                        .error_name = try app.allocator.dupe(u8, "command_failed"),
                        .data = result.data,
                    };
                }
            }

            break :blk StepOutcome{
                .index = index,
                .argv = argv_summary,
                .ok = true,
                .data = result.data,
            };
        };

        freeArgv(app.allocator, argv);
        try outcomes.append(app.allocator, outcome);

        if (outcome.ok) {
            succeeded += 1;
        } else {
            failed += 1;
            switch (mode) {
                .stop => stop = true,
                .@"continue" => {},
                .atomic => {
                    for (snapshots.items) |item| {
                        scene_undo.writeSnapshot(app.io, item.backup_path, item.scene_path) catch {};
                    }
                    rolled_back = true;
                    stop = true;
                },
            }
        }
    }

    if (mode == .atomic and failed == 0) {
        for (snapshots.items) |item| {
            std.Io.Dir.cwd().deleteFile(app.io, item.backup_path) catch {};
        }
    }

    return .{
        .mode = try app.allocator.dupe(u8, mode.toString()),
        .step_count = outcomes.items.len,
        .succeeded_count = succeeded,
        .failed_count = failed,
        .rolled_back = rolled_back,
        .steps = try outcomes.toOwnedSlice(app.allocator),
    };
}

fn readArgv(allocator: std.mem.Allocator, step_value: *const std.json.Value) Error![]const []const u8 {
    if (step_value.* != .object) return error.InvalidBatch;
    const argv_value = step_value.object.get("argv") orelse return error.MissingBatchField;
    if (argv_value != .array) return error.InvalidBatch;

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    for (argv_value.array.items) |*item| {
        const text = try jsonString(item);
        try argv.append(allocator, try allocator.dupe(u8, text));
    }
    return try argv.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn readStringArray(allocator: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList([]const u8)) Error!void {
    if (value != .array) return error.InvalidBatch;
    for (value.array.items) |*item| {
        const text = try jsonString(item);
        try out.append(allocator, try allocator.dupe(u8, text));
    }
}

fn jsonString(value: *const std.json.Value) Error![]const u8 {
    return switch (value.*) {
        .string => |s| s,
        else => error.InvalidBatch,
    };
}

fn argvToString(allocator: std.mem.Allocator, argv: []const []const u8) Error![]const u8 {
    if (argv.len == 0) return try allocator.dupe(u8, "");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, arg);
    }
    return try buf.toOwnedSlice(allocator);
}

test "batch stop mode stops on first failure" {
    const allocator = std.testing.allocator;
    const commands = @import("../commands.zig");
    const app = app_mod.App{
        .root = &commands.root,
        .io = std.testing.io,
        .allocator = allocator,
    };

    const batch =
        \\{
        \\  "mode": "stop",
        \\  "steps": [
        \\    { "argv": ["ping"] },
        \\    { "argv": ["definitely-not-a-command"] }
        \\  ]
        \\}
    ;

    var result = try runBatch(&app, batch, true);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
    try std.testing.expectEqual(@as(usize, 1), result.succeeded_count);
    try std.testing.expectEqual(@as(usize, 1), result.failed_count);
}
