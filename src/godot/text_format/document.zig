//! Structural parser for Godot `.tscn` / `.tres` text files (headers + raw properties).

const std = @import("std");
const tag = @import("tag.zig");

pub const PropertyLine = struct {
    line: usize,
    raw: []const u8,
};

pub const Section = struct {
    line: usize,
    leading_blank_lines: usize = 0,
    header: tag.Tag,
    properties: std.ArrayList(PropertyLine),

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        for (self.properties.items) |prop| allocator.free(prop.raw);
        self.properties.deinit(allocator);
    }
};

pub const Document = struct {
    sections: std.ArrayList(Section),

    pub fn init(allocator: std.mem.Allocator) Document {
        _ = allocator;
        return .{
            .sections = .empty,
        };
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
    }
};

pub const ParseError = error{
    Io,
    OutOfMemory,
    InvalidHeader,
    UnexpectedEof,
    InvalidSyntax,
    SectionNotFound,
};

pub const EditError = error{
    OutOfMemory,
    SectionNotFound,
    InvalidIndex,
};

pub fn appendSection(doc: *Document, allocator: std.mem.Allocator, section: Section) EditError!usize {
    try doc.sections.append(allocator, section);
    return doc.sections.items.len - 1;
}

pub fn insertSection(doc: *Document, allocator: std.mem.Allocator, index: usize, section: Section) EditError!void {
    if (index > doc.sections.items.len) return error.InvalidIndex;
    try doc.sections.insert(allocator, index, section);
}

pub fn removeSection(doc: *Document, index: usize) EditError!Section {
    if (index >= doc.sections.items.len) return error.SectionNotFound;
    return doc.sections.orderedRemove(index);
}

pub fn firstNodeSectionIndex(doc: *const Document) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "node")) return index;
    }
    return null;
}

pub fn lastNodeSectionIndex(doc: *const Document) ?usize {
    var last: ?usize = null;
    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "node")) last = index;
    }
    return last;
}

pub fn findSectionIndexByNodeName(doc: *const Document, node_name: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "node")) continue;
        if (section.header.getString("name")) |name| {
            if (std.mem.eql(u8, name, node_name)) return index;
        }
    }
    return null;
}

pub fn findSectionIndexByLine(doc: *const Document, line: usize) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (section.line == line) return index;
    }
    return null;
}

pub fn findSectionIndexByTagName(doc: *const Document, tag_name: []const u8) ?usize {
    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, tag_name)) return index;
    }
    return null;
}

pub fn setSectionProperty(
    doc: *Document,
    allocator: std.mem.Allocator,
    section_index: usize,
    property_name: []const u8,
    value: []const u8,
) EditError!void {
    if (section_index >= doc.sections.items.len) return error.SectionNotFound;
    const section = &doc.sections.items[section_index];

    const new_line = try allocator.print("{s} = {s}", .{ property_name, value });
    for (section.properties.items, 0..) |prop, prop_index| {
        if (propertyNameEquals(prop.raw, property_name)) {
            allocator.free(section.properties.items[prop_index].raw);
            section.properties.items[prop_index].raw = new_line;
            return;
        }
    }

    try section.properties.append(allocator, .{ .line = 0, .raw = new_line });
}

fn propertyNameEquals(raw: []const u8, property_name: []const u8) bool {
    const sep = std.mem.indexOf(u8, raw, " = ") orelse return false;
    return std.mem.eql(u8, raw[0..sep], property_name);
}

pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit(allocator);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var current: ?Section = null;
    var pending_blank_lines: usize = 0;
    // A value that runs over several lines: a string holding newlines, or
    // a dictionary or array Godot writes one entry per line. Its lines are
    // kept byte for byte in one property, blank and indented ones included;
    // read line by line, a text's indentation was trimmed, its blank lines
    // moved out of it, and a line of BBCode starting `[` became a section.
    var open_value: ?ValueScan = null;

    while (lines.next()) |line| {
        line_no += 1;
        if (open_value) |*scan| {
            const section = &current.?;
            const property = &section.properties.items[section.properties.items.len - 1];
            const content = std.mem.trimEnd(u8, line, "\r");
            const joined = try std.mem.concat(allocator, u8, &.{ property.raw, "\n", content });
            allocator.free(property.raw);
            property.raw = joined;
            scan.feed(content);
            if (scan.complete()) {
                // The closing line is trimmed at its end, as a one-line
                // value is.
                const trimmed_end = std.mem.trimEnd(u8, property.raw, &std.ascii.whitespace);
                if (trimmed_end.len != property.raw.len) {
                    const shorter = try allocator.dupe(u8, trimmed_end);
                    allocator.free(property.raw);
                    property.raw = shorter;
                }
                open_value = null;
            }
            continue;
        }
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            pending_blank_lines += 1;
            continue;
        }

        if (trimmed[0] == '[') {
            if (current) |section| {
                try doc.sections.append(allocator, section);
            }

            const header = try tag.parseLine(allocator, trimmed);
            current = Section{
                .line = line_no,
                .leading_blank_lines = pending_blank_lines,
                .header = header,
                .properties = .empty,
            };
            pending_blank_lines = 0;
            continue;
        }

        if (current) |*section| {
            var scan: ValueScan = .{};
            if (std.mem.indexOf(u8, trimmed, " = ")) |equals| scan.feed(trimmed[equals + 3 ..]) else scan.feed(trimmed);
            // An open value keeps its first line's trailing spaces: they are
            // inside the string.
            const kept = if (scan.complete()) trimmed else std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), &std.ascii.whitespace);
            const raw = try allocator.dupe(u8, kept);
            try section.properties.append(allocator, .{ .line = line_no, .raw = raw });
            if (!scan.complete()) open_value = scan;
        }
    }

    if (current) |section| {
        try doc.sections.append(allocator, section);
    }

    return doc;
}

/// Whether a value's text so far has closed every string and bracket it
/// opened. Godot escapes a quote inside a string as `\"`.
const ValueScan = struct {
    in_string: bool = false,
    escaped: bool = false,
    depth: i64 = 0,

    fn feed(self: *ValueScan, text: []const u8) void {
        for (text) |c| {
            if (self.in_string) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (c == '\\') {
                    self.escaped = true;
                } else if (c == '"') {
                    self.in_string = false;
                }
                continue;
            }
            switch (c) {
                '"' => self.in_string = true,
                '(', '[', '{' => self.depth += 1,
                ')', ']', '}' => self.depth -= 1,
                else => {},
            }
        }
        // A newline inside a string is content, not an escape's target.
        self.escaped = false;
    }

    fn complete(self: *const ValueScan) bool {
        return !self.in_string and self.depth <= 0;
    }
};

pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ParseError!Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

fn cloneTagValue(allocator: std.mem.Allocator, value: tag.Value) ParseError!tag.Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .raw => |s| .{ .raw = try allocator.dupe(u8, s) },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
    };
}

pub fn cloneDocument(allocator: std.mem.Allocator, src: *const Document) ParseError!Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit(allocator);

    for (src.sections.items) |section| {
        var header = tag.Tag{ .name = try allocator.dupe(u8, section.header.name), .fields = .{} };
        errdefer header.deinit(allocator);

        var field_it = section.header.fields.iterator();
        while (field_it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try header.fields.put(allocator, key, try cloneTagValue(allocator, entry.value_ptr.*));
        }

        var props: std.ArrayList(PropertyLine) = .empty;
        errdefer {
            for (props.items) |prop| allocator.free(prop.raw);
            props.deinit(allocator);
        }
        for (section.properties.items) |prop| {
            try props.append(allocator, .{
                .line = prop.line,
                .raw = try allocator.dupe(u8, prop.raw),
            });
        }

        try doc.sections.append(allocator, .{
            .line = section.line,
            .leading_blank_lines = section.leading_blank_lines,
            .header = header,
            .properties = props,
        });
    }

    return doc;
}

test "clone document is independent" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\visible = true
        \\
    ;
    var original = try parseBytes(allocator, source);
    defer original.deinit(allocator);

    var copy = try cloneDocument(allocator, &original);
    defer copy.deinit(allocator);

    try setSectionProperty(&copy, allocator, 1, "visible", "false");
    try std.testing.expectEqualStrings("visible = true", original.sections.items[1].properties.items[0].raw);
    try std.testing.expectEqualStrings("visible = false", copy.sections.items[1].properties.items[0].raw);
}

test "parse sample scene structure" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://foo.gd" id="1_ldc4g"]
        \\
        \\[node name="Root" type="Node"]
        \\script = ExtResource("1_ldc4g")
        \\
    ;

    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), doc.sections.items.len);
    try std.testing.expectEqualStrings("gd_scene", doc.sections.items[0].header.name);
    try std.testing.expectEqual(@as(usize, 1), doc.sections.items[2].properties.items.len);
}

test "set section property replaces existing" {
    const allocator = std.testing.allocator;
    const source =
        \\[node name="Root" type="Node"]
        \\visible = true
        \\
    ;
    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try setSectionProperty(&doc, allocator, 0, "visible", "false");
    try std.testing.expectEqualStrings("visible = false", doc.sections.items[0].properties.items[0].raw);
}

test "set bool property after variant format" {
    const allocator = std.testing.allocator;
    const variant_mod = @import("../variant/root.zig");
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var parsed = try variant_mod.parse.parsePropertyValue(allocator, "true");
    const formatted = try parsed.formatForWrite(allocator);
    parsed.deinit(allocator);
    defer allocator.free(formatted);

    try setSectionProperty(&doc, allocator, 1, "unique_name_in_owner", formatted);
    try std.testing.expectEqualStrings("unique_name_in_owner = true", doc.sections.items[1].properties.items[0].raw);
}

test "insert and remove sections" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var child_header = tag.Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
    try child_header.setStringField(allocator, "name", "Child");
    try child_header.setStringField(allocator, "type", "Node2D");
    try child_header.setStringField(allocator, "parent", ".");

    const child = Section{
        .line = 0,
        .leading_blank_lines = 1,
        .header = child_header,
        .properties = .empty,
    };

    const index = try appendSection(&doc, allocator, child);
    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expectEqual(@as(usize, 3), doc.sections.items.len);

    _ = try removeSection(&doc, index);
    try std.testing.expectEqual(@as(usize, 2), doc.sections.items.len);
    child_header.deinit(allocator);
}

test "insert section preserves round trip" {
    const allocator = std.testing.allocator;
    const writer = @import("writer.zig");
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://foo.gd" id="1_x"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var node_header = tag.Tag{ .name = try allocator.dupe(u8, "node"), .fields = .{} };
    try node_header.setStringField(allocator, "name", "Player");
    try node_header.setStringField(allocator, "type", "Node2D");
    try node_header.setStringField(allocator, "parent", ".");

    const insert_at = firstNodeSectionIndex(&doc).? + 1;
    try insertSection(&doc, allocator, insert_at, .{
        .line = 0,
        .leading_blank_lines = 0,
        .header = node_header,
        .properties = .empty,
    });

    const written = try writer.writeDocument(allocator, &doc);
    defer allocator.free(written);

    var reparsed = try parseBytes(allocator, written);
    defer reparsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), reparsed.sections.items.len);
    try std.testing.expectEqualStrings("Player", reparsed.sections.items[insert_at].header.getString("name").?);
}
