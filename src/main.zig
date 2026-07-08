const std = @import("std");

const app = @import("cli/app.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !void {
    const cli = app.App{
        .root = &commands.root,
        .io = init.io,
        .allocator = init.arena.allocator(),
    };

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const exit_code = cli.run(args);
    std.process.exit(@intFromEnum(exit_code));
}
