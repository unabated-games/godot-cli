//! Parser for Godot text resource section headers like `[gd_scene format=3]`.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    bool: bool,
};

pub const Tag = struct {
    name: []const u8,
    fields: std.StringArrayHashMapUnmanaged(Value),

    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        self.fields.deinit(allocator);
    }

    pub fn getString(self: *const Tag, key: []const u8) ?[]const u8 {
        const value = self.fields.get(key) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }
};

pub const ParseError = error{
    InvalidHeader,
    UnexpectedEof,
    InvalidSyntax,
    OutOfMemory,
};

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) ParseError!Tag {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidHeader;
    }

    var tag = Tag{
        .name = "",
        .fields = .{},
    };
    errdefer tag.deinit(allocator);

    var index: usize = 1;
    const end = trimmed.len - 1;

    tag.name = try readIdentifier(allocator, trimmed, &index, end);
    if (tag.name.len == 0) return error.InvalidSyntax;

    while (index < end) {
        skipWhitespace(trimmed, &index, end);
        if (index >= end) break;

        const key = try readIdentifier(allocator, trimmed, &index, end);
        errdefer allocator.free(key);
        skipWhitespace(trimmed, &index, end);
        if (index >= end or trimmed[index] != '=') return error.InvalidSyntax;
        index += 1;
        skipWhitespace(trimmed, &index, end);

        const value = try readValue(allocator, trimmed, &index, end);
        const key_copy = try allocator.dupe(u8, key);
        allocator.free(key);
        try tag.fields.put(allocator, key_copy, value);
    }

    return tag;
}

fn skipWhitespace(text: []const u8, index: *usize, end: usize) void {
    while (index.* < end and std.ascii.isWhitespace(text[index.*])) index.* += 1;
}

fn readIdentifier(allocator: std.mem.Allocator, text: []const u8, index: *usize, end: usize) ParseError![]u8 {
    const start = index.*;
    while (index.* < end) {
        const c = text[index.*];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':') {
            index.* += 1;
            continue;
        }
        break;
    }
    if (index.* == start) return error.InvalidSyntax;
    return try allocator.dupe(u8, text[start..index.*]);
}

fn readValue(allocator: std.mem.Allocator, text: []const u8, index: *usize, end: usize) ParseError!Value {
    if (index.* >= end) return error.UnexpectedEof;

    if (text[index.*] == '"') {
        index.* += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        while (index.* < end) {
            const c = text[index.*];
            if (c == '"') {
                index.* += 1;
                return .{ .string = try out.toOwnedSlice(allocator) };
            }
            if (c == '\\') {
                index.* += 1;
                if (index.* >= end) return error.UnexpectedEof;
                try out.append(allocator, text[index.*]);
            } else {
                try out.append(allocator, c);
            }
            index.* += 1;
        }
        return error.UnexpectedEof;
    }

    const start = index.*;
    while (index.* < end and !std.ascii.isWhitespace(text[index.*])) index.* += 1;
    const token = text[start..index.*];

    if (std.mem.eql(u8, token, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, token, "false")) return .{ .bool = false };

    if (std.fmt.parseInt(i64, token, 10)) |value| {
        return .{ .integer = value };
    } else |_| {}

    if (std.fmt.parseFloat(f64, token)) |value| {
        return .{ .float = value };
    } else |_| {}

    return .{ .string = try allocator.dupe(u8, token) };
}

test "parse gd_scene header" {
    const allocator = std.testing.allocator;
    var tag = try parseLine(allocator, "[gd_scene load_steps=2 format=3 uid=\"uid://c8wekfd5ql7bc\"]");
    defer tag.deinit(allocator);

    try std.testing.expectEqualStrings("gd_scene", tag.name);
    try std.testing.expectEqual(@as(i64, 3), tag.fields.get("format").?.integer);
    try std.testing.expectEqualStrings("uid://c8wekfd5ql7bc", tag.getString("uid").?);
}

test "parse ext_resource header" {
    const allocator = std.testing.allocator;
    var tag = try parseLine(allocator, "[ext_resource type=\"Script\" path=\"res://foo.gd\" id=\"1_ldc4g\"]");
    defer tag.deinit(allocator);

    try std.testing.expectEqualStrings("ext_resource", tag.name);
    try std.testing.expectEqualStrings("1_ldc4g", tag.getString("id").?);
}
