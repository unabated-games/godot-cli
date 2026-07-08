//! Godot Variant kinds representable in `.tscn` / `.tres` property text.
//! Mirrors `core/variant/variant_parser.cpp` incrementally; unknown values use `.raw`.

pub const Kind = enum {
    null,
    bool,
    integer,
    float,
    string,
    string_name,
    color,
    vector2,
    vector2i,
    vector3,
    vector3i,
    vector4,
    vector4i,
    rect2,
    rect2i,
    plane,
    quaternion,
    aabb,
    transform2d,
    basis,
    transform3d,
    projection,
    node_path,
    ext_resource,
    sub_resource,
    resource,
    rid,
    signal,
    callable,
    array,
    typed_array,
    dictionary,
    typed_dictionary,
    packed_array,
    object,
    raw,
};

pub fn isResourceReference(kind: Kind) bool {
    return kind == .ext_resource or kind == .sub_resource or kind == .resource;
}

pub fn ownsString(kind: Kind) bool {
    return switch (kind) {
        .string, .string_name, .node_path, .ext_resource, .sub_resource, .resource, .typed_array, .typed_dictionary, .object => true,
        else => false,
    };
}
