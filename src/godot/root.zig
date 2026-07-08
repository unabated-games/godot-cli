//! Godot-compatible primitives for scene and resource tooling.
pub const hash = @import("hash.zig");
pub const pcg = @import("pcg.zig");
pub const resource_uid = @import("resource_uid.zig");
pub const scene_id = @import("scene_id.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
