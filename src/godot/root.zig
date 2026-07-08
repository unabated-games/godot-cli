//! Godot-compatible primitives for scene and resource tooling.
pub const hash = @import("hash.zig");
pub const pcg = @import("pcg.zig");
pub const resource_uid = @import("resource_uid.zig");
pub const scene_id = @import("scene_id.zig");
pub const node_id = @import("node_id.zig");
pub const uid_cache = @import("uid_cache.zig");
pub const project_config = @import("project_config.zig");
pub const text_format = @import("text_format/root.zig");
pub const id_validate = @import("id_validate.zig");
pub const id_session = @import("id_session.zig");
pub const variant = @import("variant/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
