const std = @import("std");
const spec = @import("spec.zig");

pub const JsonRequest = struct {
    argv: []const []const u8 = &.{},
    command: []const []const u8 = &.{},
    positional: []const []const u8 = &.{},
    options: std.json.ObjectMap = .{},
};

pub const ParseError = spec.CliError;

pub fn parseJsonSlice(allocator: std.mem.Allocator, text: []const u8) ParseError!JsonRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch return error.JsonInput;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.JsonInput;

    return decodeRequest(allocator, root.object) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JsonInput,
    };
}

pub fn invocationFromRequest(
    allocator: std.mem.Allocator,
    root: *const spec.CommandSpec,
    request: JsonRequest,
) ParseError!spec.Invocation {
    if (request.argv.len != 0) {
        return @import("parser.zig").parseArgv(allocator, root, request.argv);
    }

    if (request.command.len == 0) return error.Usage;

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, request.command.len + request.positional.len + request.options.count());
    errdefer argv.deinit(allocator);

    for (request.command) |segment| try argv.append(allocator, segment);
    try applyOptionsToArgv(allocator, &argv, request.options);
    for (request.positional) |positional| try argv.append(allocator, positional);

    return @import("parser.zig").parseArgv(allocator, root, argv.items);
}

fn decodeRequest(allocator: std.mem.Allocator, object: std.json.ObjectMap) ParseError!JsonRequest {
    var request: JsonRequest = .{};

    if (object.get("argv")) |value| {
        request.argv = try decodeStringArray(allocator, value);
    }
    if (object.get("command")) |value| {
        request.command = try decodeStringArray(allocator, value);
    }
    if (object.get("positional")) |value| {
        request.positional = try decodeStringArray(allocator, value);
    }
    if (object.get("options")) |value| {
        if (value != .object) return error.JsonInput;
        request.options = try cloneObjectMap(allocator, value.object);
    }

    return request;
}

fn decodeStringArray(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array) return error.JsonInput;

    const copy = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.JsonInput;
        copy[i] = try allocator.dupe(u8, item.string);
    }
    return copy;
}

fn cloneObjectMap(allocator: std.mem.Allocator, object: std.json.ObjectMap) ParseError!std.json.ObjectMap {
    var copy = std.json.ObjectMap{};
    errdefer copy.deinit(allocator);

    try copy.ensureTotalCapacity(allocator, object.count());
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try cloneValue(allocator, entry.value_ptr.*);
        try copy.put(allocator, key, value);
    }
    return copy;
}

fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) ParseError!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| .{ .number_string = try allocator.dupe(u8, ns) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var copy = std.json.Array.init(allocator);
            errdefer copy.deinit();
            try copy.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| try copy.append(try cloneValue(allocator, item));
            break :blk .{ .array = copy };
        },
        .object => |obj| blk: {
            break :blk .{ .object = try cloneObjectMap(allocator, obj) };
        },
    };
}

fn applyOptionsToArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    options: std.json.ObjectMap,
) ParseError!void {
    var it = options.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        switch (value) {
            .bool => |enabled| {
                if (!enabled) continue;
                const flag = try std.fmt.allocPrint(allocator, "--{s}", .{key});
                try argv.append(allocator, flag);
            },
            .string => |text| {
                const flag = try std.fmt.allocPrint(allocator, "--{s}={s}", .{ key, text });
                try argv.append(allocator, flag);
            },
            .integer => |num| {
                const flag = try std.fmt.allocPrint(allocator, "--{s}={d}", .{ key, num });
                try argv.append(allocator, flag);
            },
            .float => |num| {
                const flag = try std.fmt.allocPrint(allocator, "--{s}={d}", .{ key, num });
                try argv.append(allocator, flag);
            },
            else => return error.InvalidValue,
        }
    }
}

test "json request command form" {
    const commands = @import("../commands.zig");
    const allocator = std.testing.allocator;

    var request = try parseJsonSlice(allocator,
        \\{"command":["ping"],"options":{"json":true}}
    );
    defer request.options.deinit(allocator);

    var inv = try invocationFromRequest(allocator, &commands.root, request);
    defer inv.deinit(allocator);

    try std.testing.expect(inv.global.json_output);
    try std.testing.expectEqualStrings("ping", inv.path[0]);
}
