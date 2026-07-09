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
pub const node_tree = @import("node_tree.zig");
pub const scene_edit = @import("scene_edit.zig");
pub const scene_refs = @import("scene_refs.zig");
pub const scene_resources = @import("scene_resources.zig");
pub const catalog_scan = @import("catalog_scan.zig");
pub const catalog_builtins = @import("catalog_builtins.zig");
pub const catalog_show = @import("catalog_show.zig");
pub const catalog_search = @import("catalog_search.zig");
pub const catalog_export = @import("catalog_export.zig");
pub const scene_instance = @import("scene_instance.zig");
pub const resource_uid_lookup = @import("resource_uid_lookup.zig");
pub const project_godot = @import("project_godot.zig");
pub const project_input = @import("project_input.zig");
pub const project_settings = @import("project_settings.zig");
pub const project_autoload = @import("project_autoload.zig");
pub const scene_patch = @import("scene_patch.zig");
pub const scene_plan = @import("scene_plan.zig");
pub const scene_diff = @import("scene_diff.zig");
pub const scene_undo = @import("scene_undo.zig");
pub const scene_templates = @import("scene_templates.zig");
pub const cli_batch = @import("cli_batch.zig");
pub const gdscript_scan = @import("gdscript_scan.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("fixtures.zig");
}
