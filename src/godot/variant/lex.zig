//! Shared lexing helpers for Godot Variant text.

const std = @import("std");

pub const LexError = error{
    OutOfMemory,
    InvalidSyntax,
};

pub fn parseQuotedString(allocator: std.mem.Allocator, text: []const u8) LexError![]u8 {
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

pub fn quoteString(allocator: std.mem.Allocator, text: []const u8) LexError![]u8 {
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

pub fn quoteStringName(allocator: std.mem.Allocator, text: []const u8) LexError![]u8 {
    const inner = try quoteString(allocator, text);
    defer allocator.free(inner);
    return try std.fmt.allocPrint(allocator, "&{s}", .{inner});
}

pub fn validateDelimitedSyntax(text: []const u8, open_char: u8, close_char: u8) LexError!void {
    if (text.len < 2 or text[0] != open_char or text[text.len - 1] != close_char) return error.InvalidSyntax;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    for (text) |c| {
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return error.InvalidSyntax;
                depth -= 1;
            },
            else => {},
        }
    }
    if (in_string or depth != 0) return error.InvalidSyntax;
}

/// Split top-level comma-separated constructor arguments (respects strings and nesting).
pub fn splitConstructorArgs(allocator: std.mem.Allocator, args_text: []const u8) LexError![][]const u8 {
    const trimmed = std.mem.trim(u8, args_text, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        var empty: std.ArrayList([]const u8) = .empty;
        return try empty.toOwnedSlice(allocator);
    }

    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var start: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    const part = std.mem.trim(u8, trimmed[start..i], &std.ascii.whitespace);
                    try parts.append(allocator, try allocator.dupe(u8, part));
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const part = std.mem.trim(u8, trimmed[start..], &std.ascii.whitespace);
    try parts.append(allocator, try allocator.dupe(u8, part));
    return try parts.toOwnedSlice(allocator);
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub fn parseHexColor(text: []const u8) LexError![4]f64 {
    if (text.len == 0 or text[0] != '#') return error.InvalidSyntax;
    const hex = text[1..];
    const expected: usize = switch (hex.len) {
        3, 4, 6, 8 => hex.len,
        else => return error.InvalidSyntax,
    };
    _ = expected;

    var components: [4]f64 = .{ 0, 0, 0, 1 };
    const expand = hex.len == 3 or hex.len == 4;
    const channels: usize = if (hex.len == 3 or hex.len == 6) 3 else if (hex.len == 4 or hex.len == 8) 4 else return error.InvalidSyntax;

    var ci: usize = 0;
    var i: usize = 0;
    while (ci < channels) : (ci += 1) {
        const nibbles: u8 = if (expand) blk: {
            if (i >= hex.len) return error.InvalidSyntax;
            const n = std.fmt.parseInt(u8, hex[i .. i + 1], 16) catch return error.InvalidSyntax;
            i += 1;
            break :blk (n << 4) | n;
        } else blk: {
            if (i + 2 > hex.len) return error.InvalidSyntax;
            const n = std.fmt.parseInt(u8, hex[i .. i + 2], 16) catch return error.InvalidSyntax;
            i += 2;
            break :blk n;
        };
        components[ci] = @as(f64, @floatFromInt(nibbles)) / 255.0;
    }

    return components;
}

/// `stor_fix` in `variant_parser.cpp` — special float identifiers in constructor args.
pub fn parseFloatToken(text: []const u8) LexError!f64 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-inf") or std.mem.eql(u8, trimmed, "inf_neg")) return -std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "nan")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, trimmed) catch return error.InvalidSyntax;
}

/// `rtos_fix` in `variant_parser.cpp` — float text for Godot-compatible output.
pub fn formatGodotFloat(allocator: std.mem.Allocator, value: f64) LexError![]u8 {
    if (value == 0.0) return try allocator.dupe(u8, "0");
    if (std.math.isNan(value)) return try allocator.dupe(u8, "nan");
    if (value == std.math.inf(f64)) return try allocator.dupe(u8, "inf");
    if (value == -std.math.inf(f64)) return try allocator.dupe(u8, "inf_neg");

    const as_f32: f32 = @floatCast(value);
    if (@as(f64, as_f32) == value) {
        return try std.fmt.allocPrint(allocator, "{d}", .{as_f32});
    }
    return try std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn skipWhitespace(text: []const u8, index: usize) usize {
    var i = index;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (i == 0) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
        } else {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }
    return true;
}

pub fn findCommaAtDepthZero(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

pub fn extractQuotedKey(allocator: std.mem.Allocator, text: []const u8, index: *usize) LexError![]u8 {
    index.* = skipWhitespace(text, index.*);
    if (index.* >= text.len or text[index.*] != '"') return error.InvalidSyntax;
    const end = try findQuotedStringEnd(text, index.*);
    const slice = text[index.* .. end + 1];
    index.* = end + 1;
    return try parseQuotedString(allocator, slice);
}

fn findQuotedStringEnd(text: []const u8, start: usize) LexError!usize {
    if (start >= text.len or text[start] != '"') return error.InvalidSyntax;
    var escape = false;
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\') {
            escape = true;
            continue;
        }
        if (c == '"') return i;
    }
    return error.InvalidSyntax;
}

pub const ValueSlice = struct {
    value: []const u8,
    end: usize,
};

/// Scan one complete Godot Variant value from `text[index..]` (mirrors `parse_value` token consumption).
pub fn extractValueSlice(text: []const u8, start: usize) LexError!ValueSlice {
    const index = skipWhitespace(text, start);
    if (index >= text.len) return error.InvalidSyntax;

    const first = text[index];
    if (first == '"') {
        const end = try findQuotedStringEnd(text, index);
        return .{ .value = std.mem.trim(u8, text[index .. end + 1], &std.ascii.whitespace), .end = skipWhitespace(text, end + 1) };
    }
    if ((first == '&' or first == '@') and index + 1 < text.len and text[index + 1] == '"') {
        const end = try findQuotedStringEnd(text, index + 1);
        return .{ .value = std.mem.trim(u8, text[index .. end + 1], &std.ascii.whitespace), .end = skipWhitespace(text, end + 1) };
    }
    if (first == '#') {
        var i = index + 1;
        while (i < text.len and isHexDigit(text[i])) : (i += 1) {}
        return .{ .value = std.mem.trim(u8, text[index..i], &std.ascii.whitespace), .end = skipWhitespace(text, i) };
    }
    if (first == '[' or first == '{' or first == '(') {
        const close: u8 = switch (first) {
            '[' => ']',
            '{' => '}',
            '(' => ')',
            else => unreachable,
        };
        const end = try findMatchingClose(text, index, first, close);
        return .{ .value = std.mem.trim(u8, text[index .. end + 1], &std.ascii.whitespace), .end = skipWhitespace(text, end + 1) };
    }

    // Identifier, number, or constructor call.
    var i = index;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isAlphabetic(c) or c == '_' or (i > index and std.ascii.isDigit(c))) {
            i += 1;
            continue;
        }
        break;
    }

    if (i < text.len and text[i] == '(') {
        const end = try findMatchingClose(text, i, '(', ')');
        const value = std.mem.trim(u8, text[index .. end + 1], &std.ascii.whitespace);
        return .{ .value = value, .end = skipWhitespace(text, end + 1) };
    }

    // Bare number or identifier literal.
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ',') break;
        if (std.ascii.isWhitespace(c)) break;
        continue;
    }
    return .{ .value = std.mem.trim(u8, text[index..i], &std.ascii.whitespace), .end = skipWhitespace(text, i) };
}

fn findMatchingClose(text: []const u8, open_index: usize, open_char: u8, close_char: u8) LexError!usize {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i = open_index;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == open_char) {
            depth += 1;
        } else if (c == close_char) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return error.InvalidSyntax;
}

test "split constructor args respects nesting" {
    const args = try splitConstructorArgs(std.testing.allocator, "1, Vector2(1, 2), \"a,b\"");
    defer {
        for (args) |a| std.testing.allocator.free(a);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("1", args[0]);
    try std.testing.expectEqualStrings("Vector2(1, 2)", args[1]);
    try std.testing.expectEqualStrings("\"a,b\"", args[2]);
}

test "parse hex color" {
    const c = try parseHexColor("#ff8040");
    try std.testing.expectApproxEqAbs(@as(f64, 1), c[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c[1], 0.02);
}

test "parse and format godot float tokens" {
    const inf = try parseFloatToken("inf");
    try std.testing.expect(inf == std.math.inf(f64));

    const neg = try parseFloatToken("inf_neg");
    try std.testing.expect(neg == -std.math.inf(f64));

    const formatted = try formatGodotFloat(std.testing.allocator, 0.0);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("0", formatted);

    const whole = try formatGodotFloat(std.testing.allocator, 2.0);
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("2", whole);
}
