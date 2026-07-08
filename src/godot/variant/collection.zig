//! Parse and format Godot Variant array and dictionary literals.

const std = @import("std");
const Value = @import("value.zig").Value;
const lex = @import("lex.zig");

pub const DictionaryEntry = struct {
    key: []const u8,
    value: Value,

    pub fn deinit(self: *const DictionaryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }
};

pub const ParseValueFn = *const fn (std.mem.Allocator, []const u8) ParseError!Value;

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
};

pub fn parseArrayLiteral(
    allocator: std.mem.Allocator,
    text: []const u8,
    parse_value: ParseValueFn,
) ParseError![]Value {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidSyntax;
    try lex.validateDelimitedSyntax(trimmed, '[', ']');
    return parseSequenceBody(allocator, trimmed[1 .. trimmed.len - 1], parse_value);
}

pub fn parseDictionaryLiteral(
    allocator: std.mem.Allocator,
    text: []const u8,
    parse_value: ParseValueFn,
) ParseError![]DictionaryEntry {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidSyntax;
    try lex.validateDelimitedSyntax(trimmed, '{', '}');
    return parseDictionaryBody(allocator, trimmed[1 .. trimmed.len - 1], parse_value);
}

fn parseSequenceBody(allocator: std.mem.Allocator, body: []const u8, parse_value: ParseValueFn) ParseError![]Value {
    var elements: std.ArrayList(Value) = .empty;
    errdefer {
        for (elements.items) |*item| item.deinit(allocator);
        elements.deinit(allocator);
    }

    var index: usize = 0;
    while (index < body.len) {
        index = lex.skipWhitespace(body, index);
        if (index >= body.len) break;

        const slice = try lex.extractValueSlice(body, index);
        index = slice.end;
        try elements.append(allocator, try parse_value(allocator, slice.value));

        index = lex.skipWhitespace(body, index);
        if (index < body.len and body[index] == ',') {
            index += 1;
            continue;
        }
        if (index < body.len) return error.InvalidSyntax;
    }

    return try elements.toOwnedSlice(allocator);
}

fn parseDictionaryBody(allocator: std.mem.Allocator, body: []const u8, parse_value: ParseValueFn) ParseError![]DictionaryEntry {
    var entries: std.ArrayList(DictionaryEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var index: usize = 0;
    while (index < body.len) {
        index = lex.skipWhitespace(body, index);
        if (index >= body.len) break;

        const key = try lex.extractQuotedKey(allocator, body, &index);

        index = lex.skipWhitespace(body, index);
        if (index >= body.len or body[index] != ':') return error.InvalidSyntax;
        index += 1;

        const value_slice = try lex.extractValueSlice(body, index);
        index = value_slice.end;
        const nested = try parse_value(allocator, value_slice.value);

        try entries.append(allocator, .{ .key = key, .value = nested });

        index = lex.skipWhitespace(body, index);
        if (index < body.len and body[index] == ',') {
            index += 1;
            continue;
        }
        if (index < body.len) return error.InvalidSyntax;
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn formatArray(allocator: std.mem.Allocator, elements: []const Value) ParseError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (elements, 0..) |element, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const formatted = try element.formatForWrite(allocator);
        defer allocator.free(formatted);
        try buf.appendSlice(allocator, formatted);
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

pub fn formatDictionary(allocator: std.mem.Allocator, entries: []const DictionaryEntry) ParseError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try buf.append(allocator, ' ');
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const quoted_key = try lex.quoteString(allocator, entry.key);
        defer allocator.free(quoted_key);
        try buf.appendSlice(allocator, quoted_key);
        try buf.appendSlice(allocator, ": ");
        const formatted = try entry.value.formatForWrite(allocator);
        defer allocator.free(formatted);
        try buf.appendSlice(allocator, formatted);
    }
    try buf.appendSlice(allocator, " }");
    return try buf.toOwnedSlice(allocator);
}

pub fn formatPackedElements(allocator: std.mem.Allocator, name: []const u8, elements: []const Value) ParseError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '(');
    for (elements, 0..) |element, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const formatted = try element.formatForWrite(allocator);
        defer allocator.free(formatted);
        try buf.appendSlice(allocator, formatted);
    }
    try buf.append(allocator, ')');
    return try buf.toOwnedSlice(allocator);
}

test "parse and format array with nested vector" {
    const allocator = std.testing.allocator;
    const parse_value = @import("parse.zig").parsePropertyValue;

    const elements = try parseArrayLiteral(allocator, "[1, 2, Vector3(1, 2, 3)]", parse_value);
    defer {
        for (elements) |*item| item.deinit(allocator);
        allocator.free(elements);
    }

    try std.testing.expectEqual(@as(usize, 3), elements.len);
    try std.testing.expect(elements[0].kind == .integer);
    try std.testing.expect(elements[2].kind == .vector3);

    const formatted = try formatArray(allocator, elements);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("[1, 2, Vector3(1, 2, 3)]", formatted);
}

test "parse and format dictionary" {
    const allocator = std.testing.allocator;
    const parse_value = @import("parse.zig").parsePropertyValue;

    const entries = try parseDictionaryLiteral(allocator, "{ \"enabled\": true, \"count\": 3 }", parse_value);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("enabled", entries[0].key);
    try std.testing.expect(entries[0].value.kind == .bool);

    const formatted = try formatDictionary(allocator, entries);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("{ \"enabled\": true, \"count\": 3 }", formatted);
}
