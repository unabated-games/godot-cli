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

    pub fn getInteger(self: *const Tag, key: []const u8) ?i64 {
        const value = self.fields.get(key) orelse return null;
        return switch (value) {
            .integer => |n| n,
            else => null,
        };
    }

    pub fn setStringField(self: *Tag, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        if (self.fields.getPtr(key)) |existing| {
            switch (existing.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
            existing.* = .{ .string = value_copy };
            return;
        }

        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try self.fields.put(allocator, key_copy, .{ .string = value_copy });
    }

    pub fn setIntegerField(self: *Tag, allocator: std.mem.Allocator, key: []const u8, value: i64) !void {
        if (self.fields.getPtr(key)) |existing| {
            switch (existing.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
            existing.* = .{ .integer = value };
            return;
        }

        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try self.fields.put(allocator, key_copy, .{ .integer = value });
    }

    pub fn removeField(self: *Tag, allocator: std.mem.Allocator, key: []const u8) void {
        const index = self.fields.getIndex(key) orelse return;
        const removed_key = self.fields.keys()[index];
        const removed_value = self.fields.values()[index];
        self.fields.swapRemoveAt(index);
        allocator.free(removed_key);
        switch (removed_value) {
            .string => |s| allocator.free(s),
            else => {},
        }
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

pub fn formatLine(allocator: std.mem.Allocator, header: *const Tag) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    try out.appendSlice(allocator, header.name);

    var it = header.fields.iterator();
    while (it.next()) |entry| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, entry.key_ptr.*);
        try out.append(allocator, '=');
        try formatValue(allocator, &out, entry.value_ptr.*);
    }

    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn formatValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .string => |s| {
            if (isUnquotedHeaderValue(s)) {
                try out.appendSlice(allocator, s);
            } else {
                try writeQuoted(allocator, out, s);
            }
        },
        .integer => |n| {
            var buf: [32]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{n}));
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{f}));
        },
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
    }
}

fn isUnquotedHeaderValue(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "ExtResource(") or std.mem.startsWith(u8, text, "SubResource(");
}

fn writeQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
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
}

test "format ext_resource header" {
    const allocator = std.testing.allocator;
    var header = Tag{ .name = try allocator.dupe(u8, "ext_resource"), .fields = .{} };
    defer header.deinit(allocator);
    try header.fields.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "Script") });
    try header.fields.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, "res://foo.gd") });
    try header.fields.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, "1_ldc4g") });

    const line = try formatLine(allocator, &header);
    defer allocator.free(line);
    try std.testing.expectEqualStrings("[ext_resource type=\"Script\" path=\"res://foo.gd\" id=\"1_ldc4g\"]", line);
}

test "parse gd_scene header" {
    const allocator = std.testing.allocator;
    var tag = try parseLine(allocator, "[gd_scene load_steps=2 format=3 uid=\"uid://c8wekfd5ql7bc\"]");
    defer tag.deinit(allocator);

    try std.testing.expectEqualStrings("gd_scene", tag.name);
    try std.testing.expectEqual(@as(i64, 3), tag.fields.get("format").?.integer);
    try std.testing.expectEqualStrings("uid://c8wekfd5ql7bc", tag.getString("uid").?);
}

test "format node instance header" {
    const allocator = std.testing.allocator;
    var header = Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
    defer header.deinit(allocator);
    try header.setStringField(allocator, "name", "Button");
    try header.setStringField(allocator, "parent", ".");
    try header.setStringField(allocator, "instance", "ExtResource(\"1_pq8q7\")");

    const line = try formatLine(allocator, &header);
    defer allocator.free(line);
    try std.testing.expectEqualStrings("[node name=\"Button\" parent=\".\" instance=ExtResource(\"1_pq8q7\")]", line);
}

test "parse ext_resource header" {
    const allocator = std.testing.allocator;
    var tag = try parseLine(allocator, "[ext_resource type=\"Script\" path=\"res://foo.gd\" id=\"1_ldc4g\"]");
    defer tag.deinit(allocator);

    try std.testing.expectEqualStrings("ext_resource", tag.name);
    try std.testing.expectEqualStrings("1_ldc4g", tag.getString("id").?);
}
