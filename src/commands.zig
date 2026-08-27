const std = @import("std");
const spec = @import("cli/spec.zig");
const uid = @import("commands/uid.zig");
const scene = @import("commands/scene.zig");
const catalog = @import("commands/catalog.zig");
const batch = @import("commands/batch.zig");
const project = @import("commands/project.zig");
const gen = @import("commands/gen.zig");

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
        scene.sceneCommands(),
        scene.resourceCommands(),
        catalog.commands(),
        batch.commands(),
        project.commands(),
        gen.completionsCommand(),
        gen.manCommand(),
        gen.referenceCommand(),
    },
};

test "root exposes uid commands" {
    try std.testing.expectEqual(@as(usize, 11), root.children.len);
    try std.testing.expectEqualStrings("uid", root.children[2].name);
    try std.testing.expectEqualStrings("scene", root.children[3].name);
    try std.testing.expectEqualStrings("catalog", root.children[5].name);
    try std.testing.expectEqualStrings("batch", root.children[6].name);
    try std.testing.expectEqualStrings("project", root.children[7].name);
    try std.testing.expectEqualStrings("completions", root.children[8].name);
    try std.testing.expectEqualStrings("man", root.children[9].name);
    try std.testing.expectEqualStrings("reference", root.children[10].name);
}

/// Duplicate names are invisible in normal use — the parser takes the first
/// match — but they show up twice in help, twice in the generated reference,
/// and twice in every completion script. `scene new` carried a duplicate
/// `--output` for exactly that reason.
fn expectNoDuplicates(command: *const spec.CommandSpec) !void {
    for (command.options, 0..) |opt, index| {
        for (command.options[index + 1 ..]) |other| {
            if (std.mem.eql(u8, opt.long, other.long)) {
                std.debug.print("duplicate option --{s} on {s}\n", .{ opt.long, command.name });
                return error.DuplicateOption;
            }
        }
    }

    for (command.children, 0..) |child, index| {
        for (command.children[index + 1 ..]) |other| {
            if (std.mem.eql(u8, child.name, other.name)) {
                std.debug.print("duplicate subcommand {s} under {s}\n", .{ child.name, command.name });
                return error.DuplicateSubcommand;
            }
        }
        try expectNoDuplicates(&command.children[index]);
    }
}

test "no command declares an option or subcommand twice" {
    try expectNoDuplicates(&root);
}
