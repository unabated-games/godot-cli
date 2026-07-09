//! Parse and write Godot `project.godot` (INI-style sections with brace multiline values).

const std = @import("std");

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

pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, doc: *const Document) Error!void {
    const rendered = try render(allocator, doc);
    defer allocator.free(rendered);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch return error.Io;
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

        const value_region = std.mem.trim(u8, trimmed[eq + 1 ..], &std.ascii.whitespace);
        const is_brace_value = value_region.len > 0 and value_region[0] == '{';
        const value_owned: []const u8 = if (is_brace_value)
            blk: {
                const value_start = line_start + (std.mem.indexOf(u8, line, value_region) orelse eq + 1);
                const block = try readBraceBlock(allocator, bytes, value_start);
                line_start = block.end_index;
                if (line_start < bytes.len and bytes[line_start] == '\n') line_start += 1;
                break :blk block.value;
            }
        else blk: {
            line_start = if (has_newline) line_end + 1 else bytes.len;
            break :blk value_region;
        };

        if (in_preamble) {
            try appendSlice(&preamble, allocator, line);
            if (has_newline) try preamble.append(allocator, '\n');
        } else {
            const section = current_section orelse return error.InvalidFormat;
            try section.setEntry(allocator, key, value_owned);
            if (is_brace_value) allocator.free(value_owned);
        }
    }

    doc.preamble = try preamble.toOwnedSlice(allocator);
    return doc;
}

const BraceBlock = struct {
    value: []const u8,
    end_index: usize,
};

fn readBraceBlock(allocator: std.mem.Allocator, bytes: []const u8, start_index: usize) Error!BraceBlock {
    if (start_index >= bytes.len or bytes[start_index] != '{') return error.InvalidFormat;
    var depth: i32 = 0;
    var i = start_index;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    return .{
                        .value = try allocator.dupe(u8, bytes[start_index .. i + 1]),
                        .end_index = i + 1,
                    };
                }
            },
            else => {},
        }
    }
    return error.InvalidFormat;
}

fn appendSlice(list: *std.ArrayList(u8), allocator: std.mem.Allocator, slice: []const u8) Error!void {
    try list.appendSlice(allocator, slice);
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Error!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn render(allocator: std.mem.Allocator, doc: *const Document) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (doc.preamble.len > 0) {
        try out.appendSlice(allocator, doc.preamble);
        if (doc.preamble[doc.preamble.len - 1] != '\n') try out.append(allocator, '\n');
    }

    for (doc.sections.items, 0..) |section, section_index| {
        if (section_index > 0 or doc.preamble.len > 0) try out.append(allocator, '\n');
        try appendFmt(allocator, &out, "[{s}]\n", .{section.name});

        for (section.entries.items) |entry| {
            try appendFmt(allocator, &out, "{s}={s}\n", .{ entry.key, entry.value });
        }
    }

    return try out.toOwnedSlice(allocator);
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
