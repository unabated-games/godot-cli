const std = @import("std");

const help = @import("help.zig");
const json_input = @import("json_input.zig");
const parser = @import("parser.zig");
const spec = @import("spec.zig");
const emit = @import("../output/emit.zig");
const scene_resources = @import("../godot/scene_resources.zig");
const error_details = @import("../godot/error_details.zig");

pub const App = struct {
    root: *const spec.CommandSpec,
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Process environment. Defaults to empty so tests and embedders that do
    /// not care about env-based configuration can construct an `App` directly.
    environ: std.process.Environ = .empty,

    pub fn run(self: *const App, args: []const []const u8) spec.ExitCode {
        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stderr_buffer: [4096]u8 = undefined;

        var invocation = self.loadInvocation(args) catch |err| {
            const failure = emit.failureFromError(err);
            emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, true, &.{}, failure) catch {};
            return spec.ExitCode.fromError(err);
        };
        defer invocation.deinit(self.allocator);

        const inv = invocation;

        if (inv.global.version) {
            emit.emitVersion(self.io, &stdout_buffer, inv.global.json_output) catch {};
            return .success;
        }

        if (inv.global.help and inv.path.len == 0) {
            var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), self.io, &stdout_buffer);
            help.printRootHelp(&stdout_file_writer.interface, self.root) catch {};
            stdout_file_writer.interface.flush() catch {};
            return .success;
        }

        if (inv.path.len == 0) {
            const failure = emit.Failure{
                .kind = "usage",
                .message = "missing command; run with --help",
            };
            emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, inv.global.json_output, &.{}, failure) catch {};
            return .usage;
        }

        if (std.mem.eql(u8, inv.path[0], "help")) {
            if (inv.positionals.len == 0) {
                var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), self.io, &stdout_buffer);
                help.printRootHelp(&stdout_file_writer.interface, self.root) catch {};
                stdout_file_writer.interface.flush() catch {};
                return .success;
            }

            var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), self.io, &stdout_buffer);
            help.printCommandHelp(self.allocator, &stdout_file_writer.interface, self.root, inv.positionals) catch |err| {
                const failure: emit.Failure = switch (err) {
                    error.UnknownCommand => .{
                        .kind = "unknown_command",
                        .message = "unknown command",
                    },
                    else => .{
                        .kind = "io",
                        .message = "failed to render help",
                    },
                };
                emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, inv.global.json_output, inv.positionals, failure) catch {};
                return switch (err) {
                    error.UnknownCommand => .usage,
                    else => .failure,
                };
            };
            stdout_file_writer.interface.flush() catch {};
            return .success;
        }

        const command = help.findCommand(self.root, inv.path) orelse {
            const failure = emit.Failure{
                .kind = "unknown_command",
                .message = "unknown command",
            };
            emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, inv.global.json_output, inv.path, failure) catch {};
            return .usage;
        };

        if (inv.global.help) {
            var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), self.io, &stdout_buffer);
            help.printCommandHelp(self.allocator, &stdout_file_writer.interface, self.root, inv.path) catch |err| {
                const failure: emit.Failure = switch (err) {
                    error.UnknownCommand => .{
                        .kind = "unknown_command",
                        .message = "unknown command",
                    },
                    else => .{
                        .kind = "io",
                        .message = "failed to render help",
                    },
                };
                emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, inv.global.json_output, inv.path, failure) catch {};
                return switch (err) {
                    error.UnknownCommand => .usage,
                    else => .failure,
                };
            };
            stdout_file_writer.interface.flush() catch {};
            return .success;
        }

        const handler = command.handler orelse {
            var stdout_file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), self.io, &stdout_buffer);
            help.printCommandHelp(self.allocator, &stdout_file_writer.interface, self.root, inv.path) catch {};
            stdout_file_writer.interface.flush() catch {};
            return .success;
        };

        const ctx: *anyopaque = @ptrCast(@constCast(self));
        const result = handler(ctx, &inv) catch |err| {
            var failure = emit.Failure{
                .kind = "command_failed",
                .message = @errorName(err),
            };
            if (std.mem.eql(u8, @errorName(err), "DuplicateResourceId") or
                std.mem.eql(u8, @errorName(err), "DuplicateExtPath"))
            {
                if (scene_resources.conflictDetailsJson(self.allocator) catch null) |details| {
                    failure.kind = @errorName(err);
                    failure.message = if (std.mem.eql(u8, @errorName(err), "DuplicateResourceId"))
                        "scene resource id already exists in file"
                    else
                        "ext_resource path already exists in file";
                    failure.details = .{ .object = details };
                }
            }
            // Field and value errors from patches and intents carry the
            // context an agent needs to fix its own document.
            const name = @errorName(err);
            if (std.mem.eql(u8, name, "FileNotFound") or std.mem.eql(u8, name, "Io") or std.mem.eql(u8, name, "AccessDenied")) {
                if (error_details.takeJson(self.allocator) catch null) |details| {
                    failure.kind = "io";
                    failure.message = "could not write the output file";
                    failure.details = .{ .object = details };
                }
            }
            if (std.mem.eql(u8, name, "NodeNotFound")) {
                if (error_details.takeJson(self.allocator) catch null) |details| {
                    failure.kind = "node_not_found";
                    failure.message = "no such node in this scene file";
                    failure.details = .{ .object = details };
                }
            }
            if (std.mem.eql(u8, name, "InvalidPropertyValue") or
                std.mem.eql(u8, name, "MissingPatchField") or
                std.mem.eql(u8, name, "MissingIntentField"))
            {
                failure.kind = if (std.mem.eql(u8, name, "InvalidPropertyValue")) "invalid_property_value" else "missing_field";
                failure.message = if (std.mem.eql(u8, name, "InvalidPropertyValue"))
                    "property value is not valid Variant text"
                else
                    "required field is missing";
                if (error_details.takeJson(self.allocator) catch null) |details| {
                    failure.details = .{ .object = details };
                }
            }
            emit.emitFailure(self.allocator, self.io, &stdout_buffer, &stderr_buffer, inv.global.json_output, inv.path, failure) catch {};
            return .failure;
        };

        emit.emitSuccess(self.allocator, self.io, &stdout_buffer, inv.global.json_output, inv.path, result) catch {};
        return result.exit_code orelse .success;
    }

    pub fn invoke(self: *const App, argv: []const []const u8, json_output: bool) anyerror!spec.Result {
        var invocation = try parser.parseArgv(self.allocator, self.root, argv);
        defer invocation.deinit(self.allocator);
        invocation.global.json_output = json_output;

        if (invocation.path.len == 0) return error.Usage;

        const command = help.findCommand(self.root, invocation.path) orelse return error.UnknownCommand;
        const handler = command.handler orelse return error.Usage;

        const ctx: *anyopaque = @ptrCast(@constCast(self));
        return handler(ctx, &invocation);
    }

    fn loadInvocation(self: *const App, args: []const []const u8) spec.CliError!spec.Invocation {
        const cli_args = if (args.len > 1) args[1..] else @as([]const []const u8, &.{});
        var index: usize = 0;

        while (index < cli_args.len) : (index += 1) {
            const arg = cli_args[index];
            if (std.mem.eql(u8, arg, "--request")) {
                index += 1;
                if (index >= cli_args.len) return error.Usage;
                var inv = try json_input.invocationFromRequest(
                    self.allocator,
                    self.root,
                    try json_input.parseJsonSlice(self.allocator, cli_args[index]),
                );
                mergeLeadingGlobalFlags(cli_args[0 .. index - 1], &inv.global);
                return inv;
            }
            if (std.mem.eql(u8, arg, "--request-file")) {
                index += 1;
                if (index >= cli_args.len) return error.Usage;
                const text = try readFile(self.allocator, self.io, cli_args[index]);
                var inv = try json_input.invocationFromRequest(
                    self.allocator,
                    self.root,
                    try json_input.parseJsonSlice(self.allocator, text),
                );
                mergeLeadingGlobalFlags(cli_args[0 .. index - 1], &inv.global);
                return inv;
            }
            if (std.mem.eql(u8, arg, "--request-stdin")) {
                const text = try readStdin(self.allocator, self.io);
                var inv = try json_input.invocationFromRequest(
                    self.allocator,
                    self.root,
                    try json_input.parseJsonSlice(self.allocator, text),
                );
                mergeLeadingGlobalFlags(cli_args[0..index], &inv.global);
                return inv;
            }
        }

        return parser.parseArgv(self.allocator, self.root, cli_args);
    }
};

fn mergeLeadingGlobalFlags(args: []const []const u8, global: *spec.GlobalOptions) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) global.help = true;
        if (std.mem.eql(u8, arg, "--version")) global.version = true;
        if (std.mem.eql(u8, arg, "--json")) global.json_output = true;
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) global.verbose = true;
    }
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) spec.CliError![]u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
}

fn readStdin(allocator: std.mem.Allocator, io: std.Io) spec.CliError![]u8 {
    const stdin = std.Io.File.stdin();
    var buffer: [4096]u8 = undefined;
    var file_reader = stdin.reader(io, &buffer);
    return file_reader.interface.allocRemainingAlignedSentinel(allocator, .unlimited, .of(u8), null) catch |err| switch (err) {
        error.ReadFailed => return error.Io,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.Io,
    };
}
