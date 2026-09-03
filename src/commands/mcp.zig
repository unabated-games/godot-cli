//! `godot-cli mcp`: serve the command tree as MCP tools over stdio.

const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const server = @import("../mcp/server.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn mcpHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);

    // The loop owns stdout for the life of the process, so the usual result
    // emission must not run afterwards: exit directly when stdin closes.
    server.serve(std.heap.page_allocator, cli.io, cli.root, cli.environ, .{
        .project_root = inv.getOption("project-root"),
        .include_advanced = inv.flag("all-options"),
    }) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), cli.io, &buffer);
        stderr.interface.print("godot-cli mcp: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
    std.process.exit(0);
}

pub fn command() spec.CommandSpec {
    return .{
        .name = "mcp",
        .summary = "Serve the commands as MCP tools over stdio",
        .description =
        \\Speaks the Model Context Protocol on stdin and stdout so Claude Code,
        \\Cursor, and OpenCode can call every command as a tool, read the agent
        \\docs as resources, and start a session from the godot-scene-session
        \\prompt. With --project-root the server works inside that project:
        \\--project-root . is added to every call and path arguments may not
        \\leave it.
        \\
        \\  claude mcp add godot-cli -- godot-cli mcp --project-root .
        ,
        .options = &.{
            .{ .long = "project-root", .kind = .path, .description = "Godot project to serve; injected into every call and enforced on path arguments" },
            .{ .long = "all-options", .kind = .flag, .description = "Also expose the save-preparation and id-session options in the tool schemas" },
        },
        .handler = mcpHandler,
    };
}
