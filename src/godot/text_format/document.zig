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
};

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

    const new_line = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ property_name, value });
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

    while (lines.next()) |line| {
        line_no += 1;
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
            const raw = try allocator.dupe(u8, trimmed);
            try section.properties.append(allocator, .{ .line = line_no, .raw = raw });
        }
    }

    if (current) |section| {
        try doc.sections.append(allocator, section);
    }

    return doc;
}

pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ParseError!Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
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
