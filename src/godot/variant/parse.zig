//! Incremental Godot Variant text parser for property values in `.tscn` / `.tres`.
//! Full `variant_parser.cpp` coverage is deferred; this handles common edit cases.

const std = @import("std");

pub const Kind = enum {
    null,
    bool,
    integer,
    float,
    string,
    color,
    vector2,
    vector3,
    vector4,
    raw,
};

pub const Value = struct {
    kind: Kind,
    /// Original text when kind is `.raw` or for round-trip preservation.
    raw: []const u8,
    bool: bool = false,
    integer: i64 = 0,
    float: f64 = 0,
    string: []const u8 = "",
    /// Up to four components for Color / Vector types.
    components: [4]f64 = .{ 0, 0, 0, 0 },

    pub fn formatForWrite(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.kind) {
            .raw => try allocator.dupe(u8, self.raw),
            .null => try allocator.dupe(u8, "null"),
            .bool => if (self.bool) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false"),
            .integer => try std.fmt.allocPrint(allocator, "{d}", .{self.integer}),
            .float => try std.fmt.allocPrint(allocator, "{d}", .{self.float}),
            .string => try quoteString(allocator, self.string),
            .color => try std.fmt.allocPrint(allocator, "Color({d}, {d}, {d}, {d})", .{
                self.components[0], self.components[1], self.components[2], self.components[3],
            }),
            .vector2 => try std.fmt.allocPrint(allocator, "Vector2({d}, {d})", .{ self.components[0], self.components[1] }),
            .vector3 => try std.fmt.allocPrint(allocator, "Vector3({d}, {d}, {d})", .{ self.components[0], self.components[1], self.components[2] }),
            .vector4 => try std.fmt.allocPrint(allocator, "Vector4({d}, {d}, {d}, {d})", .{
                self.components[0], self.components[1], self.components[2], self.components[3],
            }),
        };
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
};

pub fn parsePropertyValue(allocator: std.mem.Allocator, text: []const u8) ParseError!Value {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .kind = .null, .raw = "" };

    if (std.mem.eql(u8, trimmed, "null")) {
        return .{ .kind = .null, .raw = try allocator.dupe(u8, trimmed) };
    }
    if (std.mem.eql(u8, trimmed, "true")) {
        return .{ .kind = .bool, .raw = try allocator.dupe(u8, trimmed), .bool = true };
    }
    if (std.mem.eql(u8, trimmed, "false")) {
        return .{ .kind = .bool, .raw = try allocator.dupe(u8, trimmed), .bool = false };
    }

    if (trimmed[0] == '"') {
        const inner = try parseQuotedString(allocator, trimmed);
        return .{ .kind = .string, .raw = try allocator.dupe(u8, trimmed), .string = inner };
    }

    if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
        return .{ .kind = .integer, .raw = try allocator.dupe(u8, trimmed), .integer = n };
    } else |_| {}

    if (std.fmt.parseFloat(f64, trimmed)) |f| {
        return .{ .kind = .float, .raw = try allocator.dupe(u8, trimmed), .float = f };
    } else |_| {}

    if (try parseConstructor(trimmed)) |parsed| {
        var value = parsed;
        value.raw = try allocator.dupe(u8, trimmed);
        return value;
    }

    // ExtResource, SubResource, arrays, dictionaries, etc.
    return .{ .kind = .raw, .raw = try allocator.dupe(u8, trimmed) };
}

fn parseConstructor(text: []const u8) ParseError!?Value {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (text[text.len - 1] != ')') return error.InvalidSyntax;

    const name = text[0..open];
    const args_text = std.mem.trim(u8, text[open + 1 .. text.len - 1], &std.ascii.whitespace);

    const kind: Kind = if (std.mem.eql(u8, name, "Color"))
        .color
    else if (std.mem.eql(u8, name, "Vector2"))
        .vector2
    else if (std.mem.eql(u8, name, "Vector3"))
        .vector3
    else if (std.mem.eql(u8, name, "Vector4"))
        .vector4
    else
        return null;

    const expected: usize = switch (kind) {
        .color, .vector4 => 4,
        .vector3 => 3,
        .vector2 => 2,
        else => unreachable,
    };

    var components: [4]f64 = .{ 0, 0, 0, 0 };
    var args = std.mem.splitScalar(u8, args_text, ',');
    var count: usize = 0;
    while (args.next()) |part| {
        if (count >= expected) return error.InvalidSyntax;
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        components[count] = std.fmt.parseFloat(f64, trimmed) catch return error.InvalidSyntax;
        count += 1;
    }
    if (count != expected) return error.InvalidSyntax;

    return .{ .kind = kind, .raw = "", .components = components };
}

fn parseQuotedString(allocator: std.mem.Allocator, text: []const u8) ParseError![]u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return error.InvalidSyntax;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 1;
    while (i + 1 < text.len) {
        const c = text[i];
        if (c == '\\') {
            i += 1;
            if (i + 1 >= text.len) return error.InvalidSyntax;
            try out.append(allocator, text[i]);
        } else {
            try out.append(allocator, c);
        }
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn quoteString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

test "parse bool and int" {
    const a = try parsePropertyValue(std.testing.allocator, "true");
    defer std.testing.allocator.free(a.raw);
    try std.testing.expect(a.kind == .bool and a.bool);

    const b = try parsePropertyValue(std.testing.allocator, "42");
    defer std.testing.allocator.free(b.raw);
    try std.testing.expect(b.kind == .integer and b.integer == 42);
}

test "parse Color and Vector3" {
    const c = try parsePropertyValue(std.testing.allocator, "Color(1, 0.5, 0.25, 1)");
    defer std.testing.allocator.free(c.raw);
    try std.testing.expect(c.kind == .color);
    try std.testing.expectApproxEqAbs(@as(f64, 1), c.components[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.components[1], 0.0001);

    const v = try parsePropertyValue(std.testing.allocator, "Vector3(1, 2, 3)");
    defer std.testing.allocator.free(v.raw);
    try std.testing.expect(v.kind == .vector3);
    try std.testing.expectApproxEqAbs(@as(f64, 2), v.components[1], 0.0001);

    const formatted = try v.formatForWrite(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("Vector3(1, 2, 3)", formatted);
}

test "parse raw ExtResource" {
    const v = try parsePropertyValue(std.testing.allocator, "ExtResource(\"1_abc\")");
    defer std.testing.allocator.free(v.raw);
    try std.testing.expect(v.kind == .raw);
}
