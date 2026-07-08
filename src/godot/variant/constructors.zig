//! Registry of Godot Variant constructor names → fixed-arity math types.
//! Variable-length packed arrays are handled separately in `parse.zig`.
//!
//! Source of truth: `godot_ref.variant_parser_cpp` (`parse_value` identifier branches).

const Kind = @import("kind.zig").Kind;

pub const Spec = struct {
    kind: Kind,
    canonical_name: []const u8,
    aliases: []const []const u8 = &.{},
    arg_count: u8,
    integer_args: bool = false,
};

pub const all = [_]Spec{
    .{ .kind = .color, .canonical_name = "Color", .arg_count = 4 },
    .{ .kind = .vector2, .canonical_name = "Vector2", .arg_count = 2 },
    .{ .kind = .vector2i, .canonical_name = "Vector2i", .arg_count = 2, .integer_args = true },
    .{ .kind = .vector3, .canonical_name = "Vector3", .arg_count = 3 },
    .{ .kind = .vector3i, .canonical_name = "Vector3i", .arg_count = 3, .integer_args = true },
    .{ .kind = .vector4, .canonical_name = "Vector4", .arg_count = 4 },
    .{ .kind = .vector4i, .canonical_name = "Vector4i", .arg_count = 4, .integer_args = true },
    .{ .kind = .rect2, .canonical_name = "Rect2", .arg_count = 4 },
    .{ .kind = .rect2i, .canonical_name = "Rect2i", .arg_count = 4, .integer_args = true },
    .{ .kind = .plane, .canonical_name = "Plane", .arg_count = 4 },
    .{ .kind = .quaternion, .canonical_name = "Quaternion", .aliases = &.{"Quat"}, .arg_count = 4 },
    .{ .kind = .aabb, .canonical_name = "AABB", .aliases = &.{"Rect3"}, .arg_count = 6 },
    .{ .kind = .transform2d, .canonical_name = "Transform2D", .aliases = &.{"Matrix32"}, .arg_count = 6 },
    .{ .kind = .basis, .canonical_name = "Basis", .aliases = &.{"Matrix3"}, .arg_count = 9 },
    .{ .kind = .transform3d, .canonical_name = "Transform3D", .aliases = &.{"Transform"}, .arg_count = 12 },
    .{ .kind = .projection, .canonical_name = "Projection", .arg_count = 16 },
};

pub const packed_array_names = [_][]const u8{
    "PackedByteArray",
    "PoolByteArray",
    "ByteArray",
    "PackedInt32Array",
    "PackedIntArray",
    "PoolIntArray",
    "IntArray",
    "PackedInt64Array",
    "PackedFloat32Array",
    "PackedRealArray",
    "PoolRealArray",
    "FloatArray",
    "PackedFloat64Array",
    "PackedStringArray",
    "PoolStringArray",
    "StringArray",
    "PackedVector2Array",
    "PoolVector2Array",
    "Vector2Array",
    "PackedVector3Array",
    "PoolVector3Array",
    "Vector3Array",
    "PackedVector4Array",
    "PoolVector4Array",
    "Vector4Array",
    "PackedColorArray",
    "PoolColorArray",
    "ColorArray",
};

pub fn findByName(name: []const u8) ?*const Spec {
    for (&all) |*spec| {
        if (std.mem.eql(u8, name, spec.canonical_name)) return spec;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) return spec;
        }
    }
    return null;
}

pub fn isPackedArrayName(name: []const u8) bool {
    for (packed_array_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn canonicalPackedArrayName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "PackedByteArray") or std.mem.eql(u8, name, "PoolByteArray") or std.mem.eql(u8, name, "ByteArray")) return "PackedByteArray";
    if (std.mem.eql(u8, name, "PackedInt32Array") or std.mem.eql(u8, name, "PackedIntArray") or std.mem.eql(u8, name, "PoolIntArray") or std.mem.eql(u8, name, "IntArray")) return "PackedInt32Array";
    if (std.mem.eql(u8, name, "PackedFloat32Array") or std.mem.eql(u8, name, "PackedRealArray") or std.mem.eql(u8, name, "PoolRealArray") or std.mem.eql(u8, name, "FloatArray")) return "PackedFloat32Array";
    if (std.mem.eql(u8, name, "PackedStringArray") or std.mem.eql(u8, name, "PoolStringArray") or std.mem.eql(u8, name, "StringArray")) return "PackedStringArray";
    if (std.mem.eql(u8, name, "PackedVector2Array") or std.mem.eql(u8, name, "PoolVector2Array") or std.mem.eql(u8, name, "Vector2Array")) return "PackedVector2Array";
    if (std.mem.eql(u8, name, "PackedVector3Array") or std.mem.eql(u8, name, "PoolVector3Array") or std.mem.eql(u8, name, "Vector3Array")) return "PackedVector3Array";
    if (std.mem.eql(u8, name, "PackedVector4Array") or std.mem.eql(u8, name, "PoolVector4Array") or std.mem.eql(u8, name, "Vector4Array")) return "PackedVector4Array";
    if (std.mem.eql(u8, name, "PackedColorArray") or std.mem.eql(u8, name, "PoolColorArray") or std.mem.eql(u8, name, "ColorArray")) return "PackedColorArray";
    return name;
}

const std = @import("std");
