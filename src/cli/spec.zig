const std = @import("std");

pub const ValueKind = enum {
    flag,
    string,
    path,
    /// A whole number; the parser rejects anything else, and the MCP schema
    /// says `integer` so a client validates before the call is made.
    integer,
};

pub const OptionSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    kind: ValueKind = .flag,
    description: []const u8,
    default_value: ?[]const u8 = null,
    /// May be given more than once; read with `Invocation.getOptionAll`.
    repeatable: bool = false,
    /// Save-preparation and id-session plumbing. Still accepted everywhere;
    /// the MCP server leaves it out of tool schemas unless started with
    /// --all-options, so 85 tools do not each carry the same six flags.
    advanced: bool = false,
    /// The handler fails with a usage error without it. Rendered in help and
    /// docs, and listed in the MCP schema's `required`.
    required: bool = false,
};

/// Separator between repeated values in the options map. NUL cannot appear in
/// an argv string, so it cannot collide with a value.
pub const repeat_separator: u8 = 0;

/// A global option, accepted before or after the command path.
///
/// Kept as data next to `OptionSpec` so `--help`, the man page, the Markdown
/// command reference, and the shell completions all render the same list.
/// `parser.zig` still recognises these names explicitly; this table is the
/// documented surface, and `cli/gen.zig` tests assert the two agree.
pub const GlobalOptionSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    kind: ValueKind = .flag,
    description: []const u8,
};

pub const global_options = [_]GlobalOptionSpec{
    .{ .long = "help", .short = 'h', .description = "Show help and exit" },
    .{ .long = "version", .description = "Show version and exit" },
    .{ .long = "json", .description = "Emit machine-readable JSON output" },
    .{ .long = "verbose", .short = 'v', .description = "Enable verbose logging on stderr" },
    .{ .long = "request", .kind = .string, .description = "Run using a JSON command descriptor" },
    .{ .long = "request-file", .kind = .path, .description = "Read JSON command descriptor from a file" },
    .{ .long = "request-stdin", .description = "Read JSON command descriptor from stdin" },
};

/// A positional argument. Declared so `--help`, the man page, the Markdown
/// reference, `reference --format json`, and the MCP tool schemas all know a
/// command takes one; handlers still read `Invocation.positionals` directly.
pub const PositionalSpec = struct {
    name: []const u8,
    description: []const u8,
    kind: ValueKind = .string,
    required: bool = true,
    /// Accepts one or more values; must be the last positional.
    variadic: bool = false,
};

pub const CommandHandler = *const fn (ctx: *anyopaque, inv: *const Invocation) anyerror!Result;

pub const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    description: ?[]const u8 = null,
    options: []const OptionSpec = &.{},
    children: []const CommandSpec = &.{},
    positionals: []const PositionalSpec = &.{},
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
        if (self.positionals.len != 0) {
            allocator.free(self.positionals);
        }
        // Keys are static option names; values are duped when parsed.
        for (self.options.values()) |value| allocator.free(value);
        self.options.deinit(allocator);
        self.* = undefined;
    }

    pub fn getOption(self: *const Invocation, long: []const u8) ?[]const u8 {
        return self.options.get(long);
    }

    pub fn flag(self: *const Invocation, long: []const u8) bool {
        return self.options.contains(long);
    }

    /// Every value given for a repeatable option, in argv order. Caller frees
    /// the slice; the strings point into the invocation.
    pub fn getOptionAll(self: *const Invocation, allocator: std.mem.Allocator, long: []const u8) ![]const []const u8 {
        const joined = self.options.get(long) orelse return try allocator.alloc([]const u8, 0);
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, joined, repeat_separator);
        while (it.next()) |part| try out.append(allocator, part);
        return try out.toOwnedSlice(allocator);
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
