//! Positional argument tables shared by the command specs. Handlers read
//! `inv.positionals` by index; these describe the same slots for help, docs,
//! and the MCP tool schemas.

const spec = @import("../cli/spec.zig");

pub const file = [_]spec.PositionalSpec{
    .{ .name = "file", .kind = .path, .description = "Scene or resource file (.tscn or .tres)" },
};
pub const file_optional = [_]spec.PositionalSpec{
    .{ .name = "file", .kind = .path, .required = false, .description = "Scene file to dry-run the expanded patch against" },
};
pub const files = [_]spec.PositionalSpec{
    .{ .name = "files", .kind = .path, .variadic = true, .description = "One or more scene or resource files" },
};
pub const file_and_node = [_]spec.PositionalSpec{
    file[0],
    .{ .name = "node", .description = "Node by viewport path, e.g. /root/Main/Player" },
};
pub const file_and_node_optional = [_]spec.PositionalSpec{
    file[0],
    .{ .name = "node", .required = false, .description = "Node by viewport path; omit when using --node-name" },
};
pub const file_and_resource_id = [_]spec.PositionalSpec{
    file[0],
    .{ .name = "id", .description = "Resource id as written in the file, e.g. CapsuleShape2D_abc12" },
};
pub const two_files = [_]spec.PositionalSpec{
    .{ .name = "a", .kind = .path, .description = "First scene file" },
    .{ .name = "b", .kind = .path, .description = "Second scene file" },
};
pub const file_and_reference = [_]spec.PositionalSpec{
    file[0],
    .{ .name = "saved", .kind = .path, .required = false, .description = "Godot-saved file to compare against; or pass --reference" },
};
pub const template = [_]spec.PositionalSpec{
    .{ .name = "template", .description = "Template id, e.g. 2d/top_down_player" },
};
pub const uid_query = [_]spec.PositionalSpec{
    .{ .name = "query", .description = "res:// path or uid:// text to look up" },
};
pub const uid_id = [_]spec.PositionalSpec{
    .{ .name = "id", .description = "Numeric UID to encode" },
};
pub const uid_text = [_]spec.PositionalSpec{
    .{ .name = "uid", .description = "uid:// text to decode" },
};
pub const catalog_id = [_]spec.PositionalSpec{
    .{ .name = "id", .description = "Catalog entry id, e.g. ui/button" },
};
pub const scene_file = [_]spec.PositionalSpec{
    .{ .name = "file", .kind = .path, .description = "Scene file (.tscn)" },
};
