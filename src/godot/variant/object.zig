//! `Object(ClassName, "prop": value, …)` — `variant_parser.cpp` ~L995.
//! Parsed structurally without ClassDB; sufficient for text round-trip and normalization.

const std = @import("std");
const Value = @import("value.zig").Value;
const lex = @import("lex.zig");

pub const Property = struct {
    key: []const u8,
    value: Value,

    pub fn deinit(self: *const Property, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }
};

pub const ParseValueFn = *const fn (std.mem.Allocator, []const u8) ParseError!Value;

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
};

pub fn parse(
    allocator: std.mem.Allocator,
    raw: []const u8,
    args_text: []const u8,
    parse_value: ParseValueFn,
) ParseError!Value {
    const trimmed_args = std.mem.trim(u8, args_text, &std.ascii.whitespace);
    const class_end = lex.findCommaAtDepthZero(trimmed_args, 0) orelse {
        const class_name = try allocator.dupe(u8, trimmed_args);
        if (class_name.len == 0 or !lex.isIdentifier(class_name)) return error.InvalidSyntax;
        return .{
            .kind = .object,
            .raw = raw,
            .string = class_name,
            .object_properties = try allocator.alloc(Property, 0),
        };
    };

    const class_name = try allocator.dupe(u8, std.mem.trim(u8, trimmed_args[0..class_end], &std.ascii.whitespace));
    if (class_name.len == 0 or !lex.isIdentifier(class_name)) return error.InvalidSyntax;

    const body = std.mem.trim(u8, trimmed_args[class_end + 1 ..], &std.ascii.whitespace);
    const properties = try parseProperties(allocator, body, parse_value);

    return .{
        .kind = .object,
        .raw = raw,
        .string = class_name,
        .object_properties = properties,
    };
}

fn parseProperties(allocator: std.mem.Allocator, body: []const u8, parse_value: ParseValueFn) ParseError![]Property {
    var props: std.ArrayList(Property) = .empty;
    errdefer {
        for (props.items) |prop| prop.deinit(allocator);
        props.deinit(allocator);
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

        try props.append(allocator, .{ .key = key, .value = nested });

        index = lex.skipWhitespace(body, index);
        if (index < body.len and body[index] == ',') {
            index += 1;
            continue;
        }
        if (index < body.len) return error.InvalidSyntax;
    }

    return try props.toOwnedSlice(allocator);
}

pub fn format(allocator: std.mem.Allocator, class_name: []const u8, properties: []const Property) ParseError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "Object(");
    try buf.appendSlice(allocator, class_name);

    for (properties) |prop| {
        try buf.append(allocator, ',');
        const quoted_key = try lex.quoteString(allocator, prop.key);
        defer allocator.free(quoted_key);
        try buf.appendSlice(allocator, quoted_key);
        try buf.append(allocator, ':');
        const formatted = try prop.value.formatForWrite(allocator);
        defer allocator.free(formatted);
        try buf.appendSlice(allocator, formatted);
    }

    try buf.append(allocator, ')');
    return try buf.toOwnedSlice(allocator);
}
