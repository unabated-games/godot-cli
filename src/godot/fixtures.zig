//! Integration tests against committed Godot fixture files.

const std = @import("std");
const document = @import("text_format/document.zig");
const property_line = @import("variant/property_line.zig");
const parse = @import("variant/parse.zig");
const Value = @import("variant/value.zig").Value;

const rich_variants_path = "test_fixtures/project/rich_variants.tscn";
const sample_material_path = "test_fixtures/project/sample_material.tres";

fn findNodeSection(doc: *const document.Document, node_name: []const u8) ?*const document.Section {
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "node")) continue;
        if (section.header.getString("name")) |name| {
            if (std.mem.eql(u8, name, node_name)) return section;
        }
    }
    return null;
}

fn findProperty(section: *const document.Section, property_name: []const u8) ?document.PropertyLine {
    for (section.properties.items) |prop| {
        const split = property_line.splitPropertyLine(prop.raw) orelse continue;
        if (std.mem.eql(u8, split.name, property_name)) return prop;
    }
    return null;
}

fn parsePropertyNamed(
    allocator: std.mem.Allocator,
    section: *const document.Section,
    property_name: []const u8,
) !Value {
    const prop = findProperty(section, property_name) orelse return error.TestExpectedEqual;
    const split = property_line.splitPropertyLine(prop.raw) orelse return error.TestExpectedEqual;
    return try parse.parsePropertyValue(allocator, split.value_text);
}

test "rich variants fixture parses Object and collections" {
    const allocator = std.testing.allocator;
    var doc = try document.parseFile(allocator, std.testing.io, rich_variants_path);
    defer doc.deinit(allocator);

    const holder = findNodeSection(&doc, "VariantHolder") orelse return error.TestExpectedEqual;

    var object_val = try parsePropertyNamed(allocator, holder, "meta_object");
    defer object_val.deinit(allocator);
    try std.testing.expect(object_val.kind == .object);
    try std.testing.expectEqualStrings("Gradient", object_val.string);
    try std.testing.expectEqual(@as(usize, 2), object_val.object_properties.?.len);

    var typed_arr = try parsePropertyNamed(allocator, holder, "meta_array");
    defer typed_arr.deinit(allocator);
    try std.testing.expect(typed_arr.kind == .typed_array);
    try std.testing.expectEqual(@as(usize, 3), typed_arr.elements.?.len);

    var typed_dict = try parsePropertyNamed(allocator, holder, "meta_dictionary");
    defer typed_dict.deinit(allocator);
    try std.testing.expect(typed_dict.kind == .typed_dictionary);
    try std.testing.expectEqual(@as(usize, 2), typed_dict.entries.?.len);

    var plain_arr = try parsePropertyNamed(allocator, holder, "meta_plain_array");
    defer plain_arr.deinit(allocator);
    try std.testing.expect(plain_arr.kind == .array);
    try std.testing.expect(plain_arr.elements.?[2].kind == .vector3);

    var plain_dict = try parsePropertyNamed(allocator, holder, "meta_plain_dictionary");
    defer plain_dict.deinit(allocator);
    try std.testing.expect(plain_dict.kind == .dictionary);

    var packed_bytes = try parsePropertyNamed(allocator, holder, "meta_packed_bytes");
    defer packed_bytes.deinit(allocator);
    try std.testing.expect(packed_bytes.kind == .packed_array);
    try std.testing.expect(packed_bytes.packed_base64);
    try std.testing.expectEqualStrings("AQID", packed_bytes.string);

    var color_val = try parsePropertyNamed(allocator, holder, "meta_color");
    defer color_val.deinit(allocator);
    try std.testing.expect(color_val.kind == .color);
}

test "sample material fixture parses color properties" {
    const allocator = std.testing.allocator;
    var doc = try document.parseFile(allocator, std.testing.io, sample_material_path);
    defer doc.deinit(allocator);

    const resource = blk: {
        for (doc.sections.items) |*section| {
            if (std.mem.eql(u8, section.header.name, "resource")) break :blk section;
        }
        return error.TestExpectedEqual;
    };

    var albedo = try parsePropertyNamed(allocator, resource, "albedo_color");
    defer albedo.deinit(allocator);
    try std.testing.expect(albedo.kind == .color);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), albedo.components_f[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), albedo.components_f[1], 0.0001);

    var emission = try parsePropertyNamed(allocator, resource, "emission");
    defer emission.deinit(allocator);
    try std.testing.expect(emission.kind == .color);
}

test "rich variants sub_resource gradient has packed arrays" {
    const allocator = std.testing.allocator;
    var doc = try document.parseFile(allocator, std.testing.io, rich_variants_path);
    defer doc.deinit(allocator);

    const gradient = blk: {
        for (doc.sections.items) |*section| {
            if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
            if (section.header.getString("type")) |ty| {
                if (std.mem.eql(u8, ty, "Gradient")) break :blk section;
            }
        }
        return error.TestExpectedEqual;
    };

    var offsets = try parsePropertyNamed(allocator, gradient, "offsets");
    defer offsets.deinit(allocator);
    try std.testing.expect(offsets.kind == .packed_array);
    try std.testing.expectEqualStrings("PackedFloat32Array", offsets.packed_name);

    var colors = try parsePropertyNamed(allocator, gradient, "colors");
    defer colors.deinit(allocator);
    try std.testing.expect(colors.kind == .packed_array);
    try std.testing.expectEqualStrings("PackedColorArray", colors.packed_name);
}

test "every Godot-saved fixture survives parse and write byte for byte" {
    // The claim godot-cli is built on. It was only ever checked against a
    // one-ext_resource file, so a blank line the writer put between two
    // ext_resources went unnoticed; multi_ext_godot_saved.tscn has three.
    const allocator = std.testing.allocator;
    const writer = @import("text_format/writer.zig");
    const paths = [_][]const u8{
        "test_fixtures/project/multi_ext_godot_saved.tscn",
        "test_fixtures/project/sample_godot_saved.tscn",
        "test_fixtures/project/rich_variants_godot_saved.tscn",
        "test_fixtures/project/instanced_child_godot_saved.tscn",
        "test_fixtures/project/sample_material_godot_saved.tres",
        "test_fixtures/project/resources/mat_godot_saved.tres",
        "test_fixtures/project/resources/shape_godot_saved.tres",
        "test_fixtures/project/resources/theme_godot_saved.tres",
    };
    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
        defer allocator.free(bytes);
        var doc = try document.parseBytes(allocator, bytes);
        defer doc.deinit(allocator);
        const written = try writer.writeDocument(allocator, &doc);
        defer allocator.free(written);
        std.testing.expectEqualStrings(bytes, written) catch |err| {
            std.debug.print("not byte-identical after a round trip: {s}\n", .{path});
            return err;
        };
    }
}
