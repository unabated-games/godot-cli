//! Incremental Godot Variant text parser for property values in `.tscn` / `.tres`.
//! Full `variant_parser.cpp` coverage is built out via `constructors.zig` and `kind.zig`.

const std = @import("std");
const Kind = @import("kind.zig").Kind;
const Value = @import("value.zig").Value;
const constructors = @import("constructors.zig");
const lex = @import("lex.zig");
const object = @import("object.zig");
const collection = @import("collection.zig");

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
};

pub fn parsePropertyValue(allocator: std.mem.Allocator, text: []const u8) ParseError!Value {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .kind = .null, .raw = "" };

    const raw = try allocator.dupe(u8, trimmed);

    if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "nil")) {
        return .{ .kind = .null, .raw = raw };
    }
    if (std.mem.eql(u8, trimmed, "true")) {
        return .{ .kind = .bool, .raw = raw, .bool_val = true };
    }
    if (std.mem.eql(u8, trimmed, "false")) {
        return .{ .kind = .bool, .raw = raw, .bool_val = false };
    }
    if (std.mem.eql(u8, trimmed, "inf")) {
        return .{ .kind = .float, .raw = raw, .float_val = std.math.inf(f64) };
    }
    if (std.mem.eql(u8, trimmed, "-inf") or std.mem.eql(u8, trimmed, "inf_neg")) {
        return .{ .kind = .float, .raw = raw, .float_val = -std.math.inf(f64) };
    }
    if (std.mem.eql(u8, trimmed, "nan")) {
        return .{ .kind = .float, .raw = raw, .float_val = std.math.nan(f64) };
    }

    if (trimmed[0] == '#') {
        const components = try lex.parseHexColor(trimmed);
        var value: Value = .{
            .kind = .color,
            .raw = raw,
            .component_count = 4,
        };
        @memcpy(value.components_f[0..4], &components);
        return value;
    }

    if (trimmed[0] == '&' and trimmed.len > 1 and trimmed[1] == '"') {
        const inner = try lex.parseQuotedString(allocator, trimmed[1..]);
        return .{ .kind = .string_name, .raw = raw, .string = inner };
    }
    // Godot 3.x StringName compatibility (`variant_parser.cpp` `@` branch).
    if (trimmed[0] == '@' and trimmed.len > 1 and trimmed[1] == '"') {
        const inner = try lex.parseQuotedString(allocator, trimmed[1..]);
        return .{ .kind = .string_name, .raw = raw, .string = inner };
    }

    if (trimmed[0] == '"') {
        const inner = try lex.parseQuotedString(allocator, trimmed);
        return .{ .kind = .string, .raw = raw, .string = inner };
    }

    if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
        return .{ .kind = .integer, .raw = raw, .integer = n };
    } else |_| {}

    if (std.fmt.parseFloat(f64, trimmed)) |f| {
        return .{ .kind = .float, .raw = raw, .float_val = f };
    } else |_| {}

    if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        const elements = collection.parseArrayLiteral(allocator, trimmed, parsePropertyValue) catch return error.InvalidSyntax;
        return .{ .kind = .array, .raw = raw, .elements = elements };
    }

    if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const entries = collection.parseDictionaryLiteral(allocator, trimmed, parsePropertyValue) catch return error.InvalidSyntax;
        return .{ .kind = .dictionary, .raw = raw, .entries = entries };
    }

    if (try parseCallForm(allocator, trimmed, raw)) |value| return value;

    return .{ .kind = .raw, .raw = raw };
}

fn parseCallForm(allocator: std.mem.Allocator, trimmed: []const u8, raw: []const u8) ParseError!?Value {
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (trimmed[trimmed.len - 1] != ')') return error.InvalidSyntax;

    const name = trimmed[0..open];
    const args_text = trimmed[open + 1 .. trimmed.len - 1];

    if (std.mem.eql(u8, name, "Object")) {
        return try object.parse(allocator, raw, args_text, parsePropertyValue);
    }
    if (std.mem.eql(u8, name, "ExtResource")) {
        const id = try parseSingleStringArg(allocator, args_text);
        return .{ .kind = .ext_resource, .raw = raw, .string = id };
    }
    if (std.mem.eql(u8, name, "SubResource")) {
        const id = try parseSingleStringArg(allocator, args_text);
        return .{ .kind = .sub_resource, .raw = raw, .string = id };
    }
    if (std.mem.eql(u8, name, "Resource")) {
        return try parseResourceRef(allocator, raw, args_text);
    }
    if (std.mem.eql(u8, name, "NodePath")) {
        const path = try parseSingleStringArg(allocator, args_text);
        return .{ .kind = .node_path, .raw = raw, .string = path };
    }
    if (std.mem.eql(u8, name, "Signal")) {
        try expectEmptyArgs(args_text);
        return .{ .kind = .signal, .raw = raw };
    }
    if (std.mem.eql(u8, name, "Callable")) {
        try expectEmptyArgs(args_text);
        return .{ .kind = .callable, .raw = raw };
    }
    if (std.mem.eql(u8, name, "RID")) {
        const trimmed_args = std.mem.trim(u8, args_text, &std.ascii.whitespace);
        if (trimmed_args.len == 0) return .{ .kind = .rid, .raw = raw };
        const n = std.fmt.parseInt(i64, trimmed_args, 10) catch return error.InvalidSyntax;
        return .{ .kind = .rid, .raw = raw, .integer = n };
    }

    if (constructors.isPackedArrayName(name)) {
        return try parsePackedArray(allocator, raw, name, args_text);
    }

    if (try parseTypedCollection(allocator, raw, name, args_text)) |value| return value;

    if (constructors.findByName(name)) |spec| {
        return try parseFixedConstructor(allocator, raw, spec, args_text);
    }

    return null;
}

fn parseFixedConstructor(allocator: std.mem.Allocator, raw: []const u8, spec: *const constructors.Spec, args_text: []const u8) ParseError!Value {
    const args = try lex.splitConstructorArgs(allocator, args_text);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    if (args.len != spec.arg_count) return error.InvalidSyntax;

    var value: Value = .{
        .kind = spec.kind,
        .raw = raw,
        .component_count = spec.arg_count,
        .integer_components = spec.integer_args,
    };

    if (spec.integer_args) {
        for (args, 0..) |part, i| {
            value.components_i[i] = std.fmt.parseInt(i64, part, 10) catch return error.InvalidSyntax;
        }
    } else {
        for (args, 0..) |part, i| {
            value.components_f[i] = try lex.parseFloatToken(part);
        }
    }

    return value;
}

fn parseResourceRef(allocator: std.mem.Allocator, raw: []const u8, args_text: []const u8) ParseError!Value {
    const args = try lex.splitConstructorArgs(allocator, args_text);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    if (args.len == 0 or args.len > 2) return error.InvalidSyntax;
    if (args.len == 2) {
        // uid + path pair — preserve verbatim (`encode_resource_reference` format).
        return .{ .kind = .resource, .raw = raw };
    }
    const path = try parseSingleStringArg(allocator, args[0]);
    return .{ .kind = .resource, .raw = raw, .string = path };
}

fn parsePackedArray(allocator: std.mem.Allocator, raw: []const u8, name: []const u8, args_text: []const u8) ParseError!Value {
    const packed_name = constructors.canonicalPackedArrayName(name);
    const trimmed_args = std.mem.trim(u8, args_text, &std.ascii.whitespace);

    if (std.mem.eql(u8, packed_name, "PackedByteArray") and trimmed_args.len > 0 and trimmed_args[0] == '"') {
        const base64 = try parseSingleStringArg(allocator, trimmed_args);
        return .{
            .kind = .packed_array,
            .raw = raw,
            .packed_name = packed_name,
            .string = base64,
            .packed_base64 = true,
        };
    }

    const wrapped = try wrapPackedArgs(allocator, trimmed_args);
    defer allocator.free(wrapped);
    const elements = try collection.parseArrayLiteral(allocator, wrapped, parsePropertyValue);
    return .{
        .kind = .packed_array,
        .raw = raw,
        .packed_name = packed_name,
        .elements = elements,
    };
}

fn wrapPackedArgs(allocator: std.mem.Allocator, args_text: []const u8) ParseError![]const u8 {
    if (args_text.len == 0) return try allocator.dupe(u8, "[]");
    const parts = try lex.splitConstructorArgs(allocator, args_text);
    defer {
        for (parts) |part| allocator.free(part);
        allocator.free(parts);
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, part);
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

fn parseTypedCollection(allocator: std.mem.Allocator, raw: []const u8, name: []const u8, args_text: []const u8) ParseError!?Value {
    if (std.mem.startsWith(u8, name, "Array[") and name[name.len - 1] == ']') {
        const sig = try allocator.dupe(u8, name["Array[".len .. name.len - 1]);
        const elements = try collection.parseArrayLiteral(allocator, args_text, parsePropertyValue);
        return .{ .kind = .typed_array, .raw = raw, .string = sig, .elements = elements };
    }
    if (std.mem.startsWith(u8, name, "Dictionary[") and name[name.len - 1] == ']') {
        const sig = try allocator.dupe(u8, name["Dictionary[".len .. name.len - 1]);
        const entries = try collection.parseDictionaryLiteral(allocator, args_text, parsePropertyValue);
        return .{ .kind = .typed_dictionary, .raw = raw, .string = sig, .entries = entries };
    }
    return null;
}

fn parseSingleStringArg(allocator: std.mem.Allocator, args_text: []const u8) ParseError![]u8 {
    const trimmed = std.mem.trim(u8, args_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, "");
    if (trimmed[0] == '"') return try lex.parseQuotedString(allocator, trimmed);
    return try allocator.dupe(u8, trimmed);
}

fn expectEmptyArgs(args_text: []const u8) ParseError!void {
    if (std.mem.trim(u8, args_text, &std.ascii.whitespace).len != 0) return error.InvalidSyntax;
}

test "parse scalars" {
    const a = try parsePropertyValue(std.testing.allocator, "true");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.kind == .bool and a.bool_val);

    const b = try parsePropertyValue(std.testing.allocator, "42");
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(b.kind == .integer and b.integer == 42);

    const sn = try parsePropertyValue(std.testing.allocator, "&\"physics_layer\"");
    defer sn.deinit(std.testing.allocator);
    try std.testing.expect(sn.kind == .string_name);
    try std.testing.expectEqualStrings("physics_layer", sn.string);
}

test "parse Color and Vector3" {
    const c = try parsePropertyValue(std.testing.allocator, "Color(1, 0.5, 0.25, 1)");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(c.kind == .color);
    try std.testing.expectApproxEqAbs(@as(f64, 1), c.components_f[0], 0.0001);

    const v = try parsePropertyValue(std.testing.allocator, "Vector3(1, 2, 3)");
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.kind == .vector3);
    const formatted = try v.formatForWrite(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("Vector3(1, 2, 3)", formatted);
}

test "parse math types" {
    const t2d = try parsePropertyValue(std.testing.allocator, "Transform2D(1, 0, 0, 1, 10, 20)");
    defer t2d.deinit(std.testing.allocator);
    try std.testing.expect(t2d.kind == .transform2d);
    try std.testing.expectEqual(@as(u8, 6), t2d.component_count);

    const basis = try parsePropertyValue(std.testing.allocator, "Basis(1, 0, 0, 0, 1, 0, 0, 0, 1)");
    defer basis.deinit(std.testing.allocator);
    try std.testing.expect(basis.kind == .basis);

    const v2i = try parsePropertyValue(std.testing.allocator, "Vector2i(10, -3)");
    defer v2i.deinit(std.testing.allocator);
    try std.testing.expect(v2i.kind == .vector2i);
    try std.testing.expectEqual(@as(i64, -3), v2i.components_i[1]);
}

test "parse NodePath array dictionary and resources" {
    const np = try parsePropertyValue(std.testing.allocator, "NodePath(\"Root/Child\")");
    defer np.deinit(std.testing.allocator);
    try std.testing.expect(np.kind == .node_path);
    try std.testing.expectEqualStrings("Root/Child", np.string);

    const arr = try parsePropertyValue(std.testing.allocator, "[1, 2, 3]");
    defer arr.deinit(std.testing.allocator);
    try std.testing.expect(arr.kind == .array);
    try std.testing.expectEqual(@as(usize, 3), arr.elements.?.len);

    const dict = try parsePropertyValue(std.testing.allocator, "{ \"enabled\": true, \"count\": 3 }");
    defer dict.deinit(std.testing.allocator);
    try std.testing.expect(dict.kind == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), dict.entries.?.len);

    const ext = try parsePropertyValue(std.testing.allocator, "ExtResource(\"1_abc\")");
    defer ext.deinit(std.testing.allocator);
    try std.testing.expect(ext.kind == .ext_resource);

    const sub = try parsePropertyValue(std.testing.allocator, "SubResource(\"CapsuleShape3D_37kl0\")");
    defer sub.deinit(std.testing.allocator);
    try std.testing.expect(sub.kind == .sub_resource);
}

test "parse packed array and hex color" {
    const packed_arr = try parsePropertyValue(std.testing.allocator, "PackedFloat32Array(1, 2.5, 3)");
    defer packed_arr.deinit(std.testing.allocator);
    try std.testing.expect(packed_arr.kind == .packed_array);
    try std.testing.expectEqualStrings("PackedFloat32Array", packed_arr.packed_name);
    try std.testing.expectEqual(@as(usize, 3), packed_arr.elements.?.len);

    const color = try parsePropertyValue(std.testing.allocator, "#ff0000");
    defer color.deinit(std.testing.allocator);
    try std.testing.expect(color.kind == .color);
}

test "parse Object constructor" {
    const text = "Object(Gradient, \"offsets\": PackedFloat32Array(0, 1), \"colors\": PackedColorArray(1, 1, 1, 1, 0, 0, 0, 1))";
    var value = try parsePropertyValue(std.testing.allocator, text);
    defer value.deinit(std.testing.allocator);

    try std.testing.expect(value.kind == .object);
    try std.testing.expectEqualStrings("Gradient", value.string);
    try std.testing.expectEqual(@as(usize, 2), value.object_properties.?.len);
    try std.testing.expect(value.object_properties.?[0].value.kind == .packed_array);

    const formatted = try value.formatForWrite(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    var reparsed = try parsePropertyValue(std.testing.allocator, formatted);
    defer reparsed.deinit(std.testing.allocator);
    try std.testing.expect(reparsed.kind == .object);
    try std.testing.expectEqualStrings("Gradient", reparsed.string);
}

test "parse Object without properties" {
    var value = try parsePropertyValue(std.testing.allocator, "Object(ImageTexture)");
    defer value.deinit(std.testing.allocator);
    try std.testing.expect(value.kind == .object);
    try std.testing.expectEqualStrings("ImageTexture", value.string);
    try std.testing.expectEqual(@as(usize, 0), value.object_properties.?.len);
}

test "parse raw unknown constructor" {
    const v = try parsePropertyValue(std.testing.allocator, "UnknownType(1, 2)");
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.kind == .raw);
}

test "parse Resource and typed collections" {
    const res = try parsePropertyValue(std.testing.allocator, "Resource(\"res://material.tres\")");
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.kind == .resource);
    try std.testing.expectEqualStrings("res://material.tres", res.string);

    const dual = try parsePropertyValue(std.testing.allocator, "Resource(\"uid://abc\", \"res://material.tres\")");
    defer dual.deinit(std.testing.allocator);
    try std.testing.expect(dual.kind == .resource);

    const typed_arr = try parsePropertyValue(std.testing.allocator, "Array[int]([1, 2, 3])");
    defer typed_arr.deinit(std.testing.allocator);
    try std.testing.expect(typed_arr.kind == .typed_array);
    try std.testing.expectEqualStrings("int", typed_arr.string);
    try std.testing.expectEqual(@as(usize, 3), typed_arr.elements.?.len);

    const typed_dict = try parsePropertyValue(std.testing.allocator, "Dictionary[String, int]({ \"a\": 1 })");
    defer typed_dict.deinit(std.testing.allocator);
    try std.testing.expect(typed_dict.kind == .typed_dictionary);
    try std.testing.expectEqualStrings("String, int", typed_dict.string);
    try std.testing.expectEqual(@as(usize, 1), typed_dict.entries.?.len);
}

test "parse constructor with inf token" {
    const v = try parsePropertyValue(std.testing.allocator, "Vector2(inf, -inf)");
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.kind == .vector2);
    try std.testing.expect(v.components_f[0] == std.math.inf(f64));
    try std.testing.expect(v.components_f[1] == -std.math.inf(f64));
}

test "parse structured array dictionary typed and packed byte array" {
    const allocator = std.testing.allocator;

    var arr = try parsePropertyValue(allocator, "[1, 2, Vector3(1, 2, 3)]");
    defer arr.deinit(allocator);
    try std.testing.expect(arr.kind == .array);
    try std.testing.expectEqual(@as(usize, 3), arr.elements.?.len);
    try std.testing.expect(arr.elements.?[2].kind == .vector3);
    const arr_fmt = try arr.formatForWrite(allocator);
    defer allocator.free(arr_fmt);
    try std.testing.expectEqualStrings("[1, 2, Vector3(1, 2, 3)]", arr_fmt);

    var dict = try parsePropertyValue(allocator, "{ \"enabled\": true, \"count\": 3 }");
    defer dict.deinit(allocator);
    try std.testing.expect(dict.kind == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), dict.entries.?.len);
    const dict_fmt = try dict.formatForWrite(allocator);
    defer allocator.free(dict_fmt);
    try std.testing.expectEqualStrings("{ \"enabled\": true, \"count\": 3 }", dict_fmt);

    var typed_arr = try parsePropertyValue(allocator, "Array[int]([1, 2, 3])");
    defer typed_arr.deinit(allocator);
    try std.testing.expect(typed_arr.kind == .typed_array);
    try std.testing.expectEqualStrings("int", typed_arr.string);
    try std.testing.expectEqual(@as(usize, 3), typed_arr.elements.?.len);
    const typed_arr_fmt = try typed_arr.formatForWrite(allocator);
    defer allocator.free(typed_arr_fmt);
    try std.testing.expectEqualStrings("Array[int]([1, 2, 3])", typed_arr_fmt);

    var typed_dict = try parsePropertyValue(allocator, "Dictionary[String, int]({ \"a\": 1 })");
    defer typed_dict.deinit(allocator);
    try std.testing.expect(typed_dict.kind == .typed_dictionary);
    try std.testing.expectEqualStrings("String, int", typed_dict.string);
    try std.testing.expectEqual(@as(usize, 1), typed_dict.entries.?.len);
    const typed_dict_fmt = try typed_dict.formatForWrite(allocator);
    defer allocator.free(typed_dict_fmt);
    try std.testing.expectEqualStrings("Dictionary[String, int]({ \"a\": 1 })", typed_dict_fmt);

    var packed_bytes = try parsePropertyValue(allocator, "PackedByteArray(\"AQID\")");
    defer packed_bytes.deinit(allocator);
    try std.testing.expect(packed_bytes.kind == .packed_array);
    try std.testing.expect(packed_bytes.packed_base64);
    try std.testing.expectEqualStrings("AQID", packed_bytes.string);
    const packed_fmt = try packed_bytes.formatForWrite(allocator);
    defer allocator.free(packed_fmt);
    try std.testing.expectEqualStrings("PackedByteArray(\"AQID\")", packed_fmt);

    var packed_floats = try parsePropertyValue(allocator, "PackedFloat32Array(1, 2.5, 3)");
    defer packed_floats.deinit(allocator);
    try std.testing.expect(packed_floats.kind == .packed_array);
    try std.testing.expectEqual(@as(usize, 3), packed_floats.elements.?.len);
    const packed_floats_fmt = try packed_floats.formatForWrite(allocator);
    defer allocator.free(packed_floats_fmt);
    try std.testing.expectEqualStrings("PackedFloat32Array(1, 2.5, 3)", packed_floats_fmt);
}
