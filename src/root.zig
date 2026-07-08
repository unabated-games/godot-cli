//! Shared library surface for the Godot CLI tooling.
pub const version = @import("version.zig");
pub const cli = @import("cli/spec.zig");
pub const commands = @import("commands.zig");
pub const output = @import("output/emit.zig");

pub const app = @import("cli/app.zig");

test {
    @import("std").testing.refAllDecls(@import("commands.zig"));
}
