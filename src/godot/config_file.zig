//! Godot's ConfigFile text: `export_presets.cfg` and
//! `.godot/export_credentials.cfg`.
//!
//! `project.godot` has its own module because ProjectSettings writes it
//! differently (a header comment, `key=value` grouped under its own rules).
//! This is `ConfigFile::_internal_save` in `core/io/config_file.cpp`:
//! `[section]`, a blank line, `key=value` lines with no spaces, and a blank
//! line between sections. A value is Variant text, which can run over several
//! lines: the editor's default ssh run scripts are multi-line strings.

const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidFormat };

pub const Entry = struct {
    key: []const u8,
    /// Variant text, exactly as it appears after the `=`.
    value: []const u8,
};

pub const Section = struct {
    name: []const u8,
    entries: std.ArrayList(Entry),
    /// 1-based line of the `[section]` header.
    line: usize,

    pub fn get(self: *const Section, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// Every string is owned by `arena`; there is nothing to free piecemeal.
pub const Document = struct {
    sections: std.ArrayList(Section),

    pub fn find(self: *const Document, name: []const u8) ?*const Section {
        for (self.sections.items) |*section| {
            if (std.mem.eql(u8, section.name, name)) return section;
        }
        return null;
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Document {
    var doc: Document = .{ .sections = .empty };
    var i: usize = 0;
    var line: usize = 1;
    while (i < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const trimmed = std.mem.trim(u8, text[i..end], " \t\r");
        if (trimmed.len == 0 or trimmed[0] == ';' or trimmed[0] == '#') {
            i = end + 1;
            line += 1;
            continue;
        }
        if (trimmed[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return error.InvalidFormat;
            try doc.sections.append(arena, .{
                .name = try arena.dupe(u8, trimmed[1..close]),
                .entries = .empty,
                .line = line,
            });
            i = end + 1;
            line += 1;
            continue;
        }
        if (doc.sections.items.len == 0) return error.InvalidFormat;
        const eq = std.mem.indexOfScalarPos(u8, text[0..end], i, '=') orelse return error.InvalidFormat;
        const key = try decodeKey(arena, std.mem.trim(u8, text[i..eq], " \t"));
        const value_end = scanValue(text, eq + 1);
        line += std.mem.count(u8, text[i..value_end], "\n") + 1;
        const value = std.mem.trim(u8, text[eq + 1 .. value_end], " \t\r");
        const section = &doc.sections.items[doc.sections.items.len - 1];
        try section.entries.append(arena, .{ .key = key, .value = try arena.dupe(u8, value) });
        i = value_end + 1;
    }
    return doc;
}

/// The end of a value that starts at `start`: the first newline outside a
/// string and outside any bracket.
fn scanValue(text: []const u8, start: usize) usize {
    var depth: usize = 0;
    var in_string = false;
    var j = start;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (in_string) {
            if (c == '\\') {
                j += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '\n' => if (depth == 0) return j,
            else => {},
        }
    }
    return text.len;
}

/// `String::property_name_encode` quotes a key holding a space, `=` or `"`;
/// a quoted key is read back without its quotes.
fn decodeKey(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        var out: std.ArrayList(u8) = .empty;
        var k: usize = 1;
        while (k + 1 < raw.len) : (k += 1) {
            if (raw[k] == '\\' and k + 2 < raw.len) k += 1;
            try out.append(arena, raw[k]);
        }
        return out.items;
    }
    return arena.dupe(u8, raw);
}

fn encodeKey(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8) Error!void {
    var needs_quotes = false;
    for (key) |c| {
        if (c == ' ' or c == '=' or c == '"' or c >= 0x80) needs_quotes = true;
    }
    if (!needs_quotes) return out.appendSlice(allocator, key);
    try out.append(allocator, '"');
    for (key) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
}

/// Text as `ConfigFile::save` writes it.
pub fn render(allocator: std.mem.Allocator, sections: []const Section) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sections, 0..) |section, index| {
        if (index > 0) try out.append(allocator, '\n');
        try out.append(allocator, '[');
        try out.appendSlice(allocator, section.name);
        try out.appendSlice(allocator, "]\n\n");
        for (section.entries.items) |entry| {
            try encodeKey(&out, allocator, entry.key);
            try out.append(allocator, '=');
            try out.appendSlice(allocator, entry.value);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "a multi-line string value and a dictionary parse as one entry each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[preset.0.options]
        \\
        \\ssh_remote_deploy/run_script="#!/usr/bin/env bash
        \\unzip -o \"{temp_dir}\" [x
        \\done"
        \\gradle_build/custom_theme_attributes={
        \\"a": 1
        \\}
        \\after=true
        \\
    ;
    const doc = try parse(arena, text);
    const section = doc.sections.items[0];
    try std.testing.expectEqual(@as(usize, 3), section.entries.items.len);
    try std.testing.expectEqualStrings("\"#!/usr/bin/env bash\nunzip -o \\\"{temp_dir}\\\" [x\ndone\"", section.get("ssh_remote_deploy/run_script").?);
    try std.testing.expectEqualStrings("{\n\"a\": 1\n}", section.get("gradle_build/custom_theme_attributes").?);
    try std.testing.expectEqualStrings("true", section.get("after").?);

    const rendered = try render(arena, doc.sections.items);
    try std.testing.expectEqualStrings(text, rendered);
}

test "the editor's own save of every platform's preset renders back byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "test_fixtures/export/godot_4_7/export_presets.cfg",
        "test_fixtures/export/godot_4_7/export_credentials.cfg",
        "test_fixtures/export/godot_4_8/export_presets.cfg",
        "test_fixtures/export/godot_4_8/export_credentials.cfg",
    }) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .unlimited);
        const doc = try parse(arena, text);
        const rendered = try render(arena, doc.sections.items);
        try std.testing.expectEqualStrings(text, rendered);
    }
}
