const std = @import("std");
const spec = @import("../cli/spec.zig");
const version = @import("../version.zig");

pub const Failure = struct {
    kind: []const u8,
    message: []const u8,
    details: std.json.Value = .null,
};

pub fn emitSuccess(
    _: std.mem.Allocator,
    io: std.Io,
    stdout_buffer: []u8,
    json_output: bool,
    path: []const []const u8,
    result: spec.Result,
) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, stdout_buffer);
    const writer = &stdout_file_writer.interface;

    if (json_output) {
        try writer.writeAll("{\"ok\":true,\"version\":\"");
        try writer.writeAll(version.version);
        try writer.writeAll("\",\"command\":");
        try writeStringArrayJson(writer, path);
        try writer.writeAll(",\"data\":");
        try writeJsonValue(writer, result.data);
        try writer.writeAll(",\"messages\":");
        try writeStringArrayJson(writer, result.messages);
        try writer.writeAll(",\"failure\":null}\n");
        try writer.flush();
        return;
    }

    for (result.messages) |message| {
        try writer.print("{s}\n", .{message});
    }

    const show_data = switch (result.data) {
        .null => false,
        .bool => result.messages.len == 0,
        else => true,
    };

    if (show_data) {
        try writeJsonValue(writer, result.data);
        try writer.writeAll("\n");
    }

    try writer.flush();
}

pub fn emitFailure(
    _: std.mem.Allocator,
    io: std.Io,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
    json_output: bool,
    path: []const []const u8,
    failure: Failure,
) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (json_output) {
        try stdout.writeAll("{\"ok\":false,\"version\":\"");
        try stdout.writeAll(version.version);
        try stdout.writeAll("\",\"command\":");
        try writeStringArrayJson(stdout, path);
        try stdout.print(",\"failure\":{{\"kind\":\"{s}\",\"message\":\"{s}\",\"details\":", .{
            failure.kind,
            failure.message,
        });
        try writeJsonValue(stdout, failure.details);
        try stdout.writeAll("}}\n");
        try stdout.flush();
        return;
    }

    var stderr_file_writer = std.Io.File.Writer.init(std.Io.File.stderr(), io, stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    try stderr.print("error[{s}]: {s}\n", .{ failure.kind, failure.message });
    if (failure.details != .null) {
        try writeJsonValue(stderr, failure.details);
        try stderr.writeAll("\n");
    }

    try stderr.flush();
}

pub fn emitVersion(io: std.Io, stdout_buffer: []u8, json_output: bool) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, stdout_buffer);
    const writer = &stdout_file_writer.interface;

    if (json_output) {
        try writer.print(
            "{{\"ok\":true,\"version\":\"{s}\",\"data\":{{\"name\":\"{s}\"}}}}\n",
            .{ version.version, version.name },
        );
        try writer.flush();
        return;
    }

    try writer.print("{s} {s}\n", .{ version.name, version.version });
    try writer.flush();
}

pub fn failureFromError(err: spec.CliError) Failure {
    return switch (err) {
        error.Usage => .{
            .kind = "usage",
            .message = "invalid or incomplete command line; run with --help",
        },
        error.UnknownCommand => .{
            .kind = "unknown_command",
            .message = "unknown command",
        },
        error.UnknownOption => .{
            .kind = "unknown_option",
            .message = "unknown option",
        },
        error.MissingValue => .{
            .kind = "missing_value",
            .message = "missing value for option",
        },
        error.InvalidValue => .{
            .kind = "invalid_value",
            .message = "invalid option value",
        },
        error.JsonInput => .{
            .kind = "json_input",
            .message = "failed to parse JSON command descriptor",
        },
        error.Io => .{
            .kind = "io",
            .message = "I/O error",
        },
        else => .{
            .kind = "internal",
            .message = @errorName(err),
        },
    };
}

fn writeStringArrayJson(writer: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try writer.writeAll(",");
        try std.json.Stringify.value(item, .{}, writer);
    }
    try writer.writeAll("]");
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{}, writer);
}
