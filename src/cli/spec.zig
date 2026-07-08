const std = @import("std");

pub const ValueKind = enum {
    flag,
    string,
    path,
};

pub const OptionSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    kind: ValueKind = .flag,
    description: []const u8,
    default_value: ?[]const u8 = null,
};

pub const CommandHandler = *const fn (ctx: *anyopaque, inv: *const Invocation) anyerror!Result;

pub const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    description: ?[]const u8 = null,
    options: []const OptionSpec = &.{},
    children: []const CommandSpec = &.{},
    handler: ?CommandHandler = null,
};

pub const GlobalOptions = struct {
    json_output: bool = false,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
};

pub const Result = struct {
    data: std.json.Value = .null,
    messages: []const []const u8 = &.{},
    exit_code: ?ExitCode = null,
};

pub const Invocation = struct {
    global: GlobalOptions = .{},
    path: []const []const u8 = &.{},
    options: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    positionals: []const []const u8 = &.{},

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.path.len != 0) {
            allocator.free(self.path);
        }
        self.options.deinit(allocator);
        self.* = undefined;
    }

    pub fn getOption(self: *const Invocation, long: []const u8) ?[]const u8 {
        return self.options.get(long);
    }

    pub fn flag(self: *const Invocation, long: []const u8) bool {
        return self.options.contains(long);
    }
};

pub const CliError = error{
    Usage,
    UnknownCommand,
    UnknownOption,
    MissingValue,
    InvalidValue,
    JsonInput,
    Io,
    OutOfMemory,
};

pub const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
    usage = 2,

    pub fn fromError(err: CliError) ExitCode {
        return switch (err) {
            error.Usage,
            error.UnknownCommand,
            error.UnknownOption,
            error.MissingValue,
            error.InvalidValue,
            error.JsonInput,
            => .usage,
            else => .failure,
        };
    }
};
