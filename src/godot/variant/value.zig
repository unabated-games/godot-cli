//! Parsed Godot Variant value with typed fields and round-trip formatting.

const std = @import("std");
const kind_mod = @import("kind.zig");
const Kind = kind_mod.Kind;
const lex = @import("lex.zig");
const object = @import("object.zig");
const collection = @import("collection.zig");

pub const Value = struct {
    kind: Kind,
    /// Original input text (always owned).
    raw: []const u8,
    bool_val: bool = false,
    integer: i64 = 0,
    float_val: f64 = 0,
    /// Owned when `Kind.ownsString(kind)`.
    string: []const u8 = "",
    components_f: [16]f64 = .{0} ** 16,
    components_i: [16]i64 = .{0} ** 16,
    component_count: u8 = 0,
    integer_components: bool = false,
    /// Canonical packed-array constructor name when kind is `.packed_array`.
    packed_name: []const u8 = "",
    /// Populated when kind is `.object`.
    object_properties: ?[]object.Property = null,
    /// Populated for `.array`, `.typed_array`, and numeric `.packed_array`.
    elements: ?[]Value = null,
    /// Populated for `.dictionary` and `.typed_dictionary`.
    entries: ?[]collection.DictionaryEntry = null,
    /// `PackedByteArray("base64…")` stores decoded base64 text in `string`.
    packed_base64: bool = false,

    pub fn deinit(self: *const Value, allocator: std.mem.Allocator) void {
        if (self.object_properties) |props| {
            for (props) |prop| {
                prop.value.deinit(allocator);
                allocator.free(prop.key);
            }
            allocator.free(props);
        }
        if (self.elements) |elements| {
            for (elements) |*element| element.deinit(allocator);
            allocator.free(elements);
        }
        if (self.entries) |entries| {
            for (entries) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }
        allocator.free(self.raw);
        if (kind_mod.ownsString(self.kind) and self.string.len > 0) allocator.free(self.string);
        if (self.kind == .packed_array and self.packed_base64 and self.string.len > 0) allocator.free(self.string);
    }

    pub fn formatForWrite(self: Value, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.kind) {
            .raw => try allocator.dupe(u8, self.raw),
            .array => if (self.elements) |elements|
                try collection.formatArray(allocator, elements)
            else
                try allocator.dupe(u8, self.raw),
            .dictionary => if (self.entries) |entries|
                try collection.formatDictionary(allocator, entries)
            else
                try allocator.dupe(u8, self.raw),
            .typed_array => if (self.elements) |elements| blk: {
                const inner = try collection.formatArray(allocator, elements);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "Array[{s}]({s})", .{ self.string, inner });
            } else try formatTypedCollection(allocator, "Array", self.string, self.raw),
            .typed_dictionary => if (self.entries) |entries| blk: {
                const inner = try collection.formatDictionary(allocator, entries);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "Dictionary[{s}]({s})", .{ self.string, inner });
            } else try formatTypedCollection(allocator, "Dictionary", self.string, self.raw),
            .resource => if (self.string.len == 0)
                try allocator.dupe(u8, self.raw)
            else
                blk: {
                    const quoted = try lex.quoteString(allocator, self.string);
                    defer allocator.free(quoted);
                    break :blk try std.fmt.allocPrint(allocator, "Resource({s})", .{quoted});
                },
            .null => try allocator.dupe(u8, "null"),
            .bool => if (self.bool_val) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false"),
            .integer => try std.fmt.allocPrint(allocator, "{d}", .{self.integer}),
            .float => try lex.formatGodotFloat(allocator, self.float_val),
            .string => try lex.quoteString(allocator, self.string),
            .string_name => try lex.quoteStringName(allocator, self.string),
            .color => try formatComponents(allocator, "Color", self.components_f[0..self.component_count]),
            .vector2 => try formatComponents(allocator, "Vector2", self.components_f[0..self.component_count]),
            .vector2i => try formatIntComponents(allocator, "Vector2i", self.components_i[0..self.component_count]),
            .vector3 => try formatComponents(allocator, "Vector3", self.components_f[0..self.component_count]),
            .vector3i => try formatIntComponents(allocator, "Vector3i", self.components_i[0..self.component_count]),
            .vector4 => try formatComponents(allocator, "Vector4", self.components_f[0..self.component_count]),
            .vector4i => try formatIntComponents(allocator, "Vector4i", self.components_i[0..self.component_count]),
            .rect2 => try formatComponents(allocator, "Rect2", self.components_f[0..self.component_count]),
            .rect2i => try formatIntComponents(allocator, "Rect2i", self.components_i[0..self.component_count]),
            .plane => try formatComponents(allocator, "Plane", self.components_f[0..self.component_count]),
            .quaternion => try formatComponents(allocator, "Quaternion", self.components_f[0..self.component_count]),
            .aabb => try formatComponents(allocator, "AABB", self.components_f[0..self.component_count]),
            .transform2d => try formatComponents(allocator, "Transform2D", self.components_f[0..self.component_count]),
            .basis => try formatComponents(allocator, "Basis", self.components_f[0..self.component_count]),
            .transform3d => try formatComponents(allocator, "Transform3D", self.components_f[0..self.component_count]),
            .projection => try formatComponents(allocator, "Projection", self.components_f[0..self.component_count]),
            .node_path => blk: {
                const quoted = try lex.quoteString(allocator, self.string);
                defer allocator.free(quoted);
                break :blk try std.fmt.allocPrint(allocator, "NodePath({s})", .{quoted});
            },
            .ext_resource => blk: {
                const quoted = try lex.quoteString(allocator, self.string);
                defer allocator.free(quoted);
                break :blk try std.fmt.allocPrint(allocator, "ExtResource({s})", .{quoted});
            },
            .sub_resource => blk: {
                const quoted = try lex.quoteString(allocator, self.string);
                defer allocator.free(quoted);
                break :blk try std.fmt.allocPrint(allocator, "SubResource({s})", .{quoted});
            },
            .rid => if (self.integer == 0 and std.mem.indexOf(u8, self.raw, "RID()") != null)
                try allocator.dupe(u8, "RID()")
            else
                try std.fmt.allocPrint(allocator, "RID({d})", .{self.integer}),
            .signal => try allocator.dupe(u8, "Signal()"),
            .callable => try allocator.dupe(u8, "Callable()"),
            .packed_array => blk: {
                if (self.packed_base64) {
                    const quoted = try lex.quoteString(allocator, self.string);
                    defer allocator.free(quoted);
                    break :blk try std.fmt.allocPrint(allocator, "PackedByteArray({s})", .{quoted});
                }
                if (self.elements) |elements| {
                    break :blk try collection.formatPackedElements(allocator, self.packed_name, elements);
                }
                const open = std.mem.indexOfScalar(u8, self.raw, '(') orelse return try allocator.dupe(u8, self.raw);
                const close = self.raw[self.raw.len - 1];
                if (close != ')') return try allocator.dupe(u8, self.raw);
                const args = self.raw[open + 1 .. self.raw.len - 1];
                break :blk try std.fmt.allocPrint(allocator, "{s}({s})", .{ self.packed_name, args });
            },
            .object => try object.format(allocator, self.string, self.object_properties orelse &.{}),
        };
    }
};

fn formatTypedCollection(allocator: std.mem.Allocator, prefix: []const u8, signature: []const u8, raw: []const u8) ![]u8 {
    const open = std.mem.indexOfScalar(u8, raw, '(') orelse return try allocator.dupe(u8, raw);
    const suffix = raw[open..];
    return try std.fmt.allocPrint(allocator, "{s}[{s}]{s}", .{ prefix, signature, suffix });
}

fn formatComponents(allocator: std.mem.Allocator, name: []const u8, parts: []const f64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '(');
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const token = try lex.formatGodotFloat(allocator, part);
        defer allocator.free(token);
        try buf.appendSlice(allocator, token);
    }
    try buf.append(allocator, ')');
    return try buf.toOwnedSlice(allocator);
}

fn formatIntComponents(allocator: std.mem.Allocator, name: []const u8, parts: []const i64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '(');
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.print(allocator, "{d}", .{part});
    }
    try buf.append(allocator, ')');
    return try buf.toOwnedSlice(allocator);
}

test "format Vector3 and ext resource" {
    var v: Value = .{
        .kind = .vector3,
        .raw = "Vector3(1, 2, 3)",
        .components_f = .{ 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .component_count = 3,
    };
    const formatted = try v.formatForWrite(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("Vector3(1, 2, 3)", formatted);

    var ext: Value = .{
        .kind = .ext_resource,
        .raw = "ExtResource(\"1_abc\")",
        .string = "1_abc",
    };
    const ext_fmt = try ext.formatForWrite(std.testing.allocator);
    defer std.testing.allocator.free(ext_fmt);
    try std.testing.expectEqualStrings("ExtResource(\"1_abc\")", ext_fmt);
}
