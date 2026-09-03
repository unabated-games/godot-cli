//! Result emission for stdout and stderr.
//!
//! Always construct std stream writers with `initStreaming`. The default
//! `File.Writer.init` uses positional mode, which pwrites at the writer's own
//! offset (starting at 0) instead of the file offset owned by the shell. On a
//! redirect (`>` or `>>`) that overwrites the start of the target file.

const std = @import("std");
const builtin = @import("builtin");
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
    result_in: spec.Result,
) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, stdout_buffer);
    const writer = &stdout_file_writer.interface;

    // Three bugs in one day serialised freed memory (0xAA bytes) as JSON
    // strings, and each was found by an agent reading garbage. In Debug
    // builds, which is what the test suite runs, a result carrying invalid
    // UTF-8 is reported as an internal failure instead of being printed.
    var result = result_in;
    if (builtin.mode == .Debug) {
        if (firstInvalidString(result.data) orelse firstInvalidStringIn(result.messages)) |bad| {
            var stderr_buffer: [512]u8 = undefined;
            var stderr_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), io, &stderr_buffer);
            try stderr_file_writer.interface.print("internal: result contains invalid UTF-8 at {s} (freed memory serialised?)\n", .{bad});
            try stderr_file_writer.interface.flush();
            result = .{ .data = .null, .messages = &.{}, .exit_code = .failure };
            if (json_output) {
                try writer.writeAll("{\"ok\":false,\"version\":\"");
                try writer.writeAll(version.version);
                try writer.writeAll("\",\"command\":");
                try writeStringArrayJson(writer, path);
                try writer.print(",\"failure\":{{\"kind\":\"internal_invalid_output\",\"message\":\"result contained invalid UTF-8; this is a godot-cli bug\",\"details\":{{\"at\":\"{s}\"}}}}}}\n", .{bad});
                try writer.flush();
                return;
            }
        }
    }

    if (json_output) {
        try writeSuccessEnvelope(writer, path, result);
        try writer.writeAll("\n");
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
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
    json_output: bool,
    path: []const []const u8,
    failure: Failure,
) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // Failure details are recorded deep in handlers and can borrow memory a
    // caller frees on the way out; Debug builds refuse to print them.
    if (builtin.mode == .Debug) {
        if (firstInvalidString(failure.details)) |bad| {
            var stderr_buffer_local: [512]u8 = undefined;
            var stderr_local = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), io, &stderr_buffer_local);
            try stderr_local.interface.print("internal: failure details contain invalid UTF-8 at {s} (freed memory serialised?)\n", .{bad});
            try stderr_local.interface.flush();
            var details: std.json.ObjectMap = .{};
            details.put(allocator, "at", .{ .string = bad }) catch {};
            const internal = Failure{ .kind = "internal_invalid_output", .message = "failure details contained invalid UTF-8; this is a godot-cli bug", .details = .{ .object = details } };
            if (json_output) {
                try writeFailureEnvelope(stdout, path, internal);
                try stdout.writeAll("\n");
                try stdout.flush();
                return;
            }
        }
    }

    if (json_output) {
        try writeFailureEnvelope(stdout, path, failure);
        try stdout.writeAll("\n");
        try stdout.flush();
        return;
    }

    var stderr_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), io, stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    try stderr.print("error[{s}]: {s}\n", .{ failure.kind, failure.message });
    if (failure.details != .null) {
        try writeJsonValue(stderr, failure.details);
        try stderr.writeAll("\n");
    }

    try stderr.flush();
}

/// The `--json` success envelope, without a trailing newline. The MCP server
/// writes the same bytes into a tool result so agents see one shape everywhere.
pub fn writeSuccessEnvelope(writer: *std.Io.Writer, path: []const []const u8, result: spec.Result) std.Io.Writer.Error!void {
    try writer.writeAll("{\"ok\":true,\"version\":\"");
    try writer.writeAll(version.version);
    try writer.writeAll("\",\"command\":");
    try writeStringArrayJson(writer, path);
    try writer.writeAll(",\"data\":");
    try writeJsonValue(writer, result.data);
    try writer.writeAll(",\"messages\":");
    try writeStringArrayJson(writer, result.messages);
    try writer.writeAll(",\"failure\":null}");
}

/// The `--json` failure envelope, without a trailing newline.
pub fn writeFailureEnvelope(writer: *std.Io.Writer, path: []const []const u8, failure: Failure) std.Io.Writer.Error!void {
    try writer.writeAll("{\"ok\":false,\"version\":\"");
    try writer.writeAll(version.version);
    try writer.writeAll("\",\"command\":");
    try writeStringArrayJson(writer, path);
    try writer.writeAll(",\"failure\":{\"kind\":");
    try std.json.Stringify.value(failure.kind, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(failure.message, .{}, writer);
    try writer.writeAll(",\"details\":");
    try writeJsonValue(writer, failure.details);
    try writer.writeAll("}}");
}

pub fn emitVersion(io: std.Io, stdout_buffer: []u8, json_output: bool) std.Io.Writer.Error!void {
    var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, stdout_buffer);
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

/// The JSON path of the first string that is not valid UTF-8, or null.
pub fn firstInvalidString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string, .number_string => |text| if (std.unicode.utf8ValidateSlice(text)) null else "data",
        .array => |arr| blk: {
            for (arr.items) |item| if (firstInvalidString(item) != null) break :blk "data[]";
            break :blk null;
        },
        .object => |obj| blk: {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!std.unicode.utf8ValidateSlice(entry.key_ptr.*)) break :blk "data key";
                if (firstInvalidString(entry.value_ptr.*) != null) break :blk entry.key_ptr.*;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn firstInvalidStringIn(messages: []const []const u8) ?[]const u8 {
    for (messages) |message| if (!std.unicode.utf8ValidateSlice(message)) return "messages";
    return null;
}

test "invalid UTF-8 in a result is located" {
    const bad = [_]u8{ 0xAA, 0xAA };
    var obj: std.json.ObjectMap = .{};
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "path", .{ .string = &bad });
    try std.testing.expectEqualStrings("path", firstInvalidString(.{ .object = obj }).?);
    try std.testing.expect(firstInvalidString(.{ .string = "fine" }) == null);
}
