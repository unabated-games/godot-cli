//! Shared library surface for the Godot CLI tooling.
pub const version = @import("version.zig");
pub const cli = @import("cli/spec.zig");
pub const commands = @import("commands.zig");
pub const output = @import("output/emit.zig");
pub const godot = @import("godot/root.zig");

pub const app = @import("cli/app.zig");

test {
    @import("std").testing.refAllDecls(@import("commands.zig"));
    // A file's `test` blocks run only when a test block reaches it, and an
    // ordinary import does not count. Nothing reached these two, so the tests
    // against committed Godot saves in fixtures.zig had never run.
    _ = @import("godot/root.zig");
    _ = @import("cli/json_input.zig");
}
