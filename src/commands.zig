const std = @import("std");
const spec = @import("cli/spec.zig");
const uid = @import("commands/uid.zig");

fn pingHandler(ctx: *anyopaque, inv: *const spec.Invocation) anyerror!spec.Result {
    _ = ctx;
    _ = inv;

    return .{
        .data = .{ .bool = true },
        .messages = &.{"pong"},
    };
}

pub const root = spec.CommandSpec{
    .name = "godot-cli",
    .summary = "Godot scene and resource tooling",
    .children = &.{
        .{
            .name = "help",
            .summary = "Show help for a command",
        },
        .{
            .name = "ping",
            .summary = "Framework health check",
            .description = "Returns a trivial response so callers can verify JSON and CLI wiring.",
            .handler = pingHandler,
        },
        uid.commands(),
    },
};

test "root exposes uid commands" {
    try std.testing.expectEqual(@as(usize, 3), root.children.len);
    try std.testing.expectEqualStrings("uid", root.children[2].name);
}
