//! Parse and write Godot `project.godot` (INI-style sections with brace multiline values).

const std = @import("std");
const io_util = @import("../io_util.zig");
const config_file = @import("config_file.zig");

pub const Error = error{
    OutOfMemory,
    Io,
    InvalidFormat,
    SectionNotFound,
};

pub const Entry = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: *const Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const Section = struct {
    name: []const u8,
    entries: std.ArrayList(Entry),

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn findEntry(self: *const Section, key: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }

    pub fn getEntry(self: *const Section, key: []const u8) ?[]const u8 {
        const index = self.findEntry(key) orelse return null;
        return self.entries.items[index].value;
    }

    pub fn removeEntry(self: *Section, allocator: std.mem.Allocator, key: []const u8) bool {
        const index = self.findEntry(key) orelse return false;
        const old = self.entries.items[index];
        allocator.free(old.key);
        allocator.free(old.value);
        _ = self.entries.orderedRemove(index);
        return true;
    }

    pub fn setEntry(self: *Section, allocator: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        if (self.findEntry(key)) |index| {
            const old = self.entries.items[index];
            allocator.free(old.key);
            allocator.free(old.value);
            self.entries.items[index] = .{ .key = key_copy, .value = value_copy };
            return;
        }

        try self.entries.append(allocator, .{ .key = key_copy, .value = value_copy });
    }
};

pub const Document = struct {
    preamble: []const u8,
    sections: std.ArrayList(Section),

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.preamble);
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
    }

    pub fn sectionIndex(self: *const Document, name: []const u8) ?usize {
        for (self.sections.items, 0..) |section, index| {
            if (std.mem.eql(u8, section.name, name)) return index;
        }
        return null;
    }

    pub fn sectionMut(self: *Document, name: []const u8) ?*Section {
        const index = self.sectionIndex(name) orelse return null;
        return &self.sections.items[index];
    }

    pub fn ensureSection(self: *Document, allocator: std.mem.Allocator, name: []const u8) Error!*Section {
        if (self.sectionMut(name)) |section| return section;
        try self.sections.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .entries = .empty,
        });
        return &self.sections.items[self.sections.items.len - 1];
    }
};

/// The engine version the project's `config/features` names ("4.7"), which
/// the editor writes on its first save; null for a project it never opened.
pub fn engineMinor(doc: *const Document) ?[]const u8 {
    const index = doc.sectionIndex("application") orelse return null;
    const features = doc.sections.items[index].getEntry("config/features") orelse return null;
    return minorFromFeatures(features);
}

/// The engine version a `config/features` value names: the first element
/// that looks like `4.7`.
pub fn minorFromFeatures(features_text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, features_text, i, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, features_text, open + 1, '"') orelse return null;
        const item = features_text[open + 1 .. close];
        if (item.len >= 3 and std.ascii.isDigit(item[0]) and item[1] == '.' and std.ascii.isDigit(item[2])) return item;
        i = close + 1;
    }
    return null;
}

pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, doc: *const Document) Error!void {
    const rendered = try render(allocator, doc);
    defer allocator.free(rendered);
    io_util.writeFileAtomic(io, path, rendered) catch return error.Io;
}

pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var doc: Document = .{
        .preamble = "",
        .sections = .empty,
    };
    errdefer doc.deinit(allocator);

    var preamble: std.ArrayList(u8) = .empty;
    errdefer preamble.deinit(allocator);

    var line_start: usize = 0;
    var in_preamble = true;
    var current_section: ?*Section = null;

    while (line_start < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
        const line = bytes[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        const has_newline = line_end < bytes.len;

        if (trimmed.len == 0 or trimmed[0] == ';') {
            if (in_preamble) {
                try appendSlice(&preamble, allocator, line);
                if (has_newline) try preamble.append(allocator, '\n');
            }
            line_start = if (has_newline) line_end + 1 else bytes.len;
            continue;
        }

        if (trimmed[0] == '[') {
            in_preamble = false;
            const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return error.InvalidFormat;
            const section_name = std.mem.trim(u8, trimmed[1..close], &std.ascii.whitespace);
            if (section_name.len == 0) return error.InvalidFormat;

            try doc.sections.append(allocator, .{
                .name = try allocator.dupe(u8, section_name),
                .entries = .empty,
            });
            current_section = &doc.sections.items[doc.sections.items.len - 1];
            line_start = if (has_newline) line_end + 1 else bytes.len;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidFormat;
        const key = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
        if (key.len == 0) return error.InvalidFormat;

        // A value runs to the first newline outside a string and outside any
        // bracket: `{...}` blocks for input actions, and quoted strings that
        // span lines, which Godot writes for a multi-line
        // `config/description`. Reading line by line failed the whole file.
        const value_start = @intFromPtr(trimmed.ptr) - @intFromPtr(bytes.ptr) + eq + 1;
        const value_end = config_file.scanValue(bytes, value_start);
        const value = std.mem.trim(u8, bytes[value_start..value_end], &std.ascii.whitespace);
        const region_end = value_end;
        line_start = if (value_end < bytes.len) value_end + 1 else bytes.len;

        if (in_preamble) {
            try appendSlice(&preamble, allocator, bytes[@intFromPtr(line.ptr) - @intFromPtr(bytes.ptr) .. region_end]);
            if (region_end < bytes.len) try preamble.append(allocator, '\n');
        } else {
            const section = current_section orelse return error.InvalidFormat;
            try section.setEntry(allocator, key, value);
        }
    }

    doc.preamble = try preamble.toOwnedSlice(allocator);
    return doc;
}

fn appendSlice(list: *std.ArrayList(u8), allocator: std.mem.Allocator, slice: []const u8) Error!void {
    try list.appendSlice(allocator, slice);
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Error!void {
    const text = try allocator.print(fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn render(allocator: std.mem.Allocator, doc: *const Document) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Godot's own layout (core/config/project_settings.cpp, _save_settings_text):
    // the preamble ends with one newline, every section is preceded by one blank
    // line and followed by one, and entries run to the end of the section. The
    // preamble is trimmed so a file written this way rewrites byte for byte.
    if (doc.preamble.len > 0) {
        try out.appendSlice(allocator, std.mem.trimEnd(u8, doc.preamble, "\n"));
        try out.append(allocator, '\n');
    }

    // Godot iterates a sorted map when it saves, so sections come out in name
    // order; a section appended by `project apply` would otherwise sit at the
    // end until the editor's next save moved it.
    const order = try allocator.alloc(usize, doc.sections.items.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, doc, struct {
        fn less(d: *const Document, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, d.sections.items[a].name, d.sections.items[b].name);
        }
    }.less);

    for (order, 0..) |section_idx, section_index| {
        const section = doc.sections.items[section_idx];
        if (section_index > 0 or doc.preamble.len > 0) try out.append(allocator, '\n');
        try appendFmt(allocator, &out, "[{s}]\n\n", .{section.name});

        for (section.entries.items) |entry| {
            try appendFmt(allocator, &out, "{s}={s}\n", .{ entry.key, entry.value });
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn unquoteValue(value: []const u8) ?[]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return null;
}

pub fn formatQuotedString(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

pub fn formatGodotValue(allocator: std.mem.Allocator, value: std.json.Value) Error![]u8 {
    return switch (value) {
        .string => |text| formatQuotedString(allocator, text),
        .integer => |n| try allocator.print("{d}", .{n}),
        .float => |f| try allocator.print("{d}", .{f}),
        .bool => |b| try allocator.print("{s}", .{if (b) "true" else "false"}),
        else => error.InvalidFormat,
    };
}

test "parse project with input section" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/input_map_snippet.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const input = doc.sectionMut("input").?;
    try std.testing.expectEqual(@as(usize, 2), input.entries.items.len);
    try std.testing.expect(std.mem.startsWith(u8, input.entries.items[0].value, "{"));
    try std.testing.expectEqualStrings("move_left", input.entries.items[0].key);
}

test "roundtrip preserves input action block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/input_map_snippet.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const rendered = try render(allocator, &doc);
    defer allocator.free(rendered);

    var doc2 = try parseBytes(allocator, rendered);
    defer doc2.deinit(allocator);

    const input = doc.sectionMut("input").?;
    const input2 = doc2.sectionMut("input").?;
    try std.testing.expectEqual(input.entries.items.len, input2.entries.items.len);
    try std.testing.expectEqualStrings(input.entries.items[0].value, input2.entries.items[0].value);
}

test "a quoted value may span lines, as Godot writes a multi-line description" {
    const allocator = std.testing.allocator;
    const source =
        \\config_version=5
        \\
        \\[application]
        \\
        \\config/name="Dodge the Creeps"
        \\config/description="This is a simple game where
        \\you avoid the enemies. [b]Not[/b] a section.
        \\
        \\Still the description; key=value too."
        \\run/main_scene="res://main.tscn"
        \\
        \\[input]
        \\
        \\start_game={
        \\"deadzone": 0.5,
        \\"events": []
        \\}
        \\
    ;
    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);
    const app = doc.sections.items[doc.sectionIndex("application").?];
    try std.testing.expectEqualStrings("\"res://main.tscn\"", app.getEntry("run/main_scene").?);
    try std.testing.expect(std.mem.endsWith(u8, app.getEntry("config/description").?, "key=value too.\""));
    try std.testing.expect(std.mem.startsWith(u8, doc.sections.items[doc.sectionIndex("input").?].getEntry("start_game").?, "{"));

    const written = try render(allocator, &doc);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(source, written);
}
