const std = @import("std");

const app = @import("cli/app.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !void {
    // Single-threaded Io avoids EINVAL on stdout after file I/O (Zig 0.16 threaded Io).
    const io = std.Io.Threaded.global_single_threaded.io();

    const cli = app.App{
        .root = &commands.root,
        .io = io,
        .allocator = init.arena.allocator(),
        .environ = init.minimal.environ,
    };

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const exit_code = cli.run(args);
    std.process.exit(@intFromEnum(exit_code));
}
