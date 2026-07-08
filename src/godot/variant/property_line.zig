//! Split `name = value` property lines and parse values via the Variant parser.

const std = @import("std");
const document = @import("../text_format/document.zig");
const parse = @import("parse.zig");
const Value = @import("value.zig").Value;

pub const Split = struct {
    name: []const u8,
    value_text: []const u8,
};

pub fn splitPropertyLine(raw: []const u8) ?Split {
    if (std.mem.indexOf(u8, raw, " = ")) |idx| {
        return .{
            .name = std.mem.trim(u8, raw[0..idx], &std.ascii.whitespace),
            .value_text = std.mem.trim(u8, raw[idx + 3 ..], &std.ascii.whitespace),
        };
    }
    if (std.mem.indexOfScalar(u8, raw, '=')) |idx| {
        return .{
            .name = std.mem.trim(u8, raw[0..idx], &std.ascii.whitespace),
            .value_text = std.mem.trim(u8, raw[idx + 1 ..], &std.ascii.whitespace),
        };
    }
    return null;
}

pub fn buildPropertiesJson(
    allocator: std.mem.Allocator,
    properties: []const document.PropertyLine,
) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (properties) |prop| {
        try arr.append(try buildPropertyJson(allocator, prop));
    }
    return arr;
}

pub fn buildPropertyJson(allocator: std.mem.Allocator, prop: document.PropertyLine) !std.json.Value {
    var row: std.json.ObjectMap = .{};
    try row.put(allocator, "line", .{ .integer = @intCast(prop.line) });
    const raw_copy = try allocator.dupe(u8, prop.raw);
    try row.put(allocator, "raw", .{ .string = raw_copy });

    const split = splitPropertyLine(prop.raw);
    const name = if (split) |parts| parts.name else "";
    const name_copy = try allocator.dupe(u8, name);
    try row.put(allocator, "name", .{ .string = name_copy });

    if (split) |parts| {
        const parsed = parse.parsePropertyValue(allocator, parts.value_text) catch {
            try row.put(allocator, "kind", .{ .string = "raw" });
            try row.put(allocator, "parse_error", .{ .bool = true });
            return .{ .object = row };
        };
        defer parsed.deinit(allocator);
        try row.put(allocator, "kind", .{ .string = @tagName(parsed.kind) });
        if (valueToJson(allocator, parsed)) |json_value| {
            try row.put(allocator, "value", json_value);
        }
    } else {
        try row.put(allocator, "kind", .{ .string = "raw" });
        try row.put(allocator, "parse_error", .{ .bool = true });
    }

    return .{ .object = row };
}

fn valueToJson(allocator: std.mem.Allocator, value: Value) ?std.json.Value {
    return switch (value.kind) {
        .null => .null,
        .bool => .{ .bool = value.bool_val },
        .integer => .{ .integer = value.integer },
        .float => .{ .float = value.float_val },
        .string, .string_name, .node_path, .ext_resource, .sub_resource, .resource => blk: {
            const copy = allocator.dupe(u8, value.string) catch return null;
            break :blk .{ .string = copy };
        },
        .rid => if (value.integer != 0 or std.mem.indexOf(u8, value.raw, "RID(") != null)
            .{ .integer = value.integer }
        else
            null,
        .signal, .callable => null,
        .color, .vector2, .vector3, .vector4, .rect2, .plane, .quaternion, .aabb, .transform2d, .basis, .transform3d, .projection => blk: {
            const count = value.component_count;
            var arr = std.json.Array.init(allocator);
            for (value.components_f[0..count]) |part| {
                arr.append(.{ .float = part }) catch return null;
            }
            break :blk .{ .array = arr };
        },
        .vector2i, .vector3i, .vector4i, .rect2i => blk: {
            const count = value.component_count;
            var arr = std.json.Array.init(allocator);
            for (value.components_i[0..count]) |part| {
                arr.append(.{ .integer = part }) catch return null;
            }
            break :blk .{ .array = arr };
        },
        .array, .dictionary, .typed_array, .typed_dictionary, .packed_array, .object, .raw => null,
    };
}

test "split property line" {
    const parts = splitPropertyLine("visible = true").?;
    try std.testing.expectEqualStrings("visible", parts.name);
    try std.testing.expectEqualStrings("true", parts.value_text);

    const tight = splitPropertyLine("radius=0.5").?;
    try std.testing.expectEqualStrings("radius", tight.name);
    try std.testing.expectEqualStrings("0.5", tight.value_text);

    try std.testing.expect(splitPropertyLine("not a property") == null);
}

test "parse split property values" {
    const allocator = std.testing.allocator;

    const bool_parts = splitPropertyLine("visible = true").?;
    var bool_val = try parse.parsePropertyValue(allocator, bool_parts.value_text);
    defer bool_val.deinit(allocator);
    try std.testing.expect(bool_val.kind == .bool);
    try std.testing.expect(bool_val.bool_val);

    const ext_parts = splitPropertyLine("script = ExtResource(\"1_abc\")").?;
    try std.testing.expectEqualStrings("script", ext_parts.name);
    var ext_val = try parse.parsePropertyValue(allocator, ext_parts.value_text);
    defer ext_val.deinit(allocator);
    try std.testing.expect(ext_val.kind == .ext_resource);
    try std.testing.expectEqualStrings("1_abc", ext_val.string);

    const float_parts = splitPropertyLine("radius = 0.5").?;
    var float_val = try parse.parsePropertyValue(allocator, float_parts.value_text);
    defer float_val.deinit(allocator);
    try std.testing.expect(float_val.kind == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), float_val.float_val, 0.0001);
}
